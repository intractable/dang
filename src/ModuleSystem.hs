{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}

module ModuleSystem (
    Scope()
  , runScope
  , scopeCheck
  ) where

import Dang.IO
import Dang.Monad
import Interface
import Pretty
import QualName
import Syntax.AST hiding (declNames)
import TypeChecker.Types
import qualified Data.ClashMap as CM

import Control.Applicative
import Data.Maybe (catMaybes)
import Data.Typeable (Typeable)
import MonadLib
import qualified Data.Foldable as F
import qualified Data.Set as Set
import qualified Data.Traversable as T


-- Scope Checking Monad --------------------------------------------------------

data RO = RO
  { roNames :: ResolvedNames
  }

emptyRO :: RO
emptyRO  = RO
  { roNames = CM.empty
  }

newtype Scope a = Scope
  { getScope :: ReaderT RO Dang a
  } deriving (Functor,Applicative,Monad)

instance ReaderM Scope RO where
  ask = Scope ask

instance RunReaderM Scope RO where
  local i m = Scope (local i (getScope m))

instance BaseM Scope Dang where
  inBase = Scope . inBase

instance ExceptionM Scope SomeException where
  raise = Scope . raise

instance RunExceptionM Scope SomeException where
  try = Scope . try . getScope

runScope :: Scope a -> Dang a
runScope  = runReaderT emptyRO . getScope


-- Errors ----------------------------------------------------------------------

data ScopeError = MissingInterface QualName
    deriving (Show,Typeable)

instance Exception ScopeError

-- | Generate a missing interface exception, with the module name that was being
-- loaded.
missingInterface :: QualName -> Scope a
missingInterface  = raiseE . MissingInterface


-- Import Gathering ------------------------------------------------------------

type ImportSet = Set.Set QualName

-- | Generate the set of module names that are affected by open declarations.
importSet :: [Open] -> ImportSet
importSet opens
  = Set.fromList
  $ catMaybes $ concat [ [Just (openMod m), openAs m] | m <- opens ]

-- | Given a @ImportSet@ and a set of implicit imports via qualified names,
-- produce a set of module names to be imported.
pruneImplicit :: ImportSet -> Set.Set QualName -> Set.Set QualName
pruneImplicit renames = (Set.\\ renames)

-- | Generate the set of module interfaces that require loading, from a
-- @Module@.
moduleImports :: Module -> Set.Set Use
moduleImports m =
  Set.fromList (map Explicit (modOpens m)) `Set.union` Set.map Implicit implicit
  where
  env      = importSet (modOpens m)
  implicit = pruneImplicit env (imports m)

data Use = Explicit Open | Implicit QualName
    deriving (Eq,Show,Ord)

usedModule :: Use -> QualName
usedModule (Explicit o)  = openMod o
usedModule (Implicit qn) = qn

-- | Collect all the implicit module imports.
class Imports a where
  imports :: a -> Set.Set QualName

instance Imports a => Imports (Maybe a) where
  imports = maybe Set.empty imports

instance Imports a => Imports [a] where
  imports = Set.unions . map imports

instance Imports Module where
  imports m = imports (modDecls m)

instance Imports Decl where
  imports d = imports (declBody d)

instance Imports Term where
  imports (Abs _ b)   = imports b
  imports (Let ds b)  = imports ds `Set.union` imports b
  imports (App f xs)  = imports f `Set.union` imports xs
  imports (Local _)   = Set.empty
  imports (Global qn) = maybe Set.empty Set.singleton (qualModule qn)
  imports (Prim _)    = Set.empty
  imports (Lit l)     = imports l

instance Imports Literal where
  imports (LInt _) = Set.empty

-- | Run a scope checking operation with the environment created by a module.
withEnv :: Module -> Scope a -> Scope (InterfaceSet, a)
withEnv m k = do
  let opened = moduleImports m
  logDebug "Opened modules:"
  logDebug (show opened)

  let need = Set.toList opened
  logDebug "Needed interfaces:"
  logDebug (show need)
  iface <- loadInterfaces opened

  let env0 = mergeResolvedNames (definedNames m) (buildEnv iface opened)
  logDebug "Module environment:"
  logDebug (show env0)

  ro  <- ask
  res <- local (ro { roNames = env0 }) k
  return (iface,res)

-- | Register all of the names defined in a module as both their local and fully
-- qualified versions.
definedNames :: Module -> ResolvedNames
definedNames m = CM.fromList
               $ concatMap primTypeNames (modPrimTypes m)
              ++ concatMap primTermNames (modPrimTerms m)
              ++ concatMap (declNames (modNamespace m)) (modDecls m)

-- | Extract the simple and qualified names that a declaration introduces.
declResolvedNames :: (a -> Name) -> (Name -> QualName)
                  -> (a -> [(QualName,Resolved)])
declResolvedNames simple qualify d = [ (simpleName n, res), (qn, res) ]
  where
  n   = simple d
  qn  = qualify n
  res = Resolved qn

-- | The resolved names from a single declaration.
declNames :: Namespace -> Decl -> [(QualName,Resolved)]
declNames ns = declResolvedNames declName (qualName ns)

-- | The resolved names form a single primitive type declaration.
primTypeNames :: PrimType -> [(QualName,Resolved)]
primTypeNames  = declResolvedNames primTypeName primName

-- | The resolved names form a single primitive term declaration.
primTermNames :: PrimTerm -> [(QualName,Resolved)]
primTermNames  = declResolvedNames primTermName primName

-- | Given all the interface obligations generated by the initial analysis, load
-- the interfaces from disk.  If an interface obligation was weak, and failed to
-- find an interface file, no error will be reported.
loadInterfaces :: Set.Set Use -> Scope InterfaceSet
loadInterfaces  = F.foldlM step emptyInterfaceSet
  where
  step is u = do
    let m = usedModule u
    e <- try (inBase (openInterface m))
    case e of
      Right iface -> return (addInterface iface is)
      Left{}      -> missingInterface m

-- | Given an aggregate interface, and a set of module uses, generate the final
-- mapping from used names to resolved names.
buildEnv :: InterfaceSet -> Set.Set Use -> ResolvedNames
buildEnv iface = F.foldr step CM.empty
  where
  step (Explicit o)  = mergeResolvedNames (resolveOpen iface o)
  step (Implicit qn) = mergeResolvedNames (resolveModule iface qn)

data Resolved
  = Resolved QualName
  | Bound Name
    deriving (Eq,Show)

type ResolvedNames = CM.ClashMap QualName Resolved

-- | True when the Resolved name is a bound variable.
isBound :: Resolved -> Bool
isBound Bound{} = True
isBound _       = False

-- | Merge resolved names, favoring new bound variables for shadowing.
mergeResolved :: CM.Strategy Resolved
mergeResolved a b
  | isBound a = CM.ok a
  | a == b    = CM.ok a
  | otherwise = CM.clash a b

-- | Merge two resolved name substitutions.
mergeResolvedNames :: ResolvedNames -> ResolvedNames -> ResolvedNames
mergeResolvedNames  = CM.unionWith mergeResolved

resolve :: QualName -> Scope Resolved
resolve qn = do
  ro <- ask
  case CM.clashElems `fmap` CM.lookup qn (roNames ro) of
    Just [r] -> return r
    Just _rs -> fail ("Symbol `" ++ pretty qn ++ "' is defined multiple times")
    Nothing  -> fail ("Symbol `" ++ pretty qn ++ "' not defined")

-- | Given a qualified name, generate the term that corresponds to its binding.
resolveTerm :: QualName -> Scope Term
resolveTerm qn = resolvedTerm `fmap` resolve qn

-- | The term that this entry represents (global/local).
resolvedTerm :: Resolved -> Term
resolvedTerm (Resolved qn) = Global qn
resolvedTerm (Bound n)     = Local n

-- | Resolve a constructor name to its qualified version.
resolveType :: QualName -> Scope QualName
resolveType qn = resolvedType =<< resolve qn

-- | The qualified type name that results from a resolved name.
resolvedType :: Resolved -> Scope QualName
resolvedType (Resolved qn) = return qn
resolvedType Bound{}       = fail "Unexpected bound variable in type"

-- | Resolve an open declaration to the module names that it involves.
resolveOpen :: InterfaceSet -> Open -> ResolvedNames
resolveOpen iface o = rename resolved
  where
  syms                    = resolveModule iface (openMod o)
  resolved | openHiding o = resolveHiding (openSymbols o) syms
           | otherwise    = resolveOnly   (openSymbols o) syms
  rename = case openAs o of
    Nothing -> id
    Just m' -> CM.mapKeys (changeNamespace (qualNamespace m'))

-- | Resolve all symbols from a module as though they were opened with no
-- qualifications.
resolveModule :: InterfaceSet -> QualName -> ResolvedNames
resolveModule iface m =
  CM.fromListWith mergeResolved (map step (modContents m iface))
  where
  step (qn,_) = (simpleName (qualSymbol qn), Resolved qn)

-- | Resolve an open declaration that hides some names, and optionally renames
-- the module.
resolveHiding :: [Name] -> ResolvedNames -> ResolvedNames
resolveHiding ns syms = foldl step syms ns
  where
  step m n = CM.delete (simpleName n) m

-- | Resolve an open declaration that selects some names, and optionally renames
-- the module.
resolveOnly :: [Name] -> ResolvedNames -> ResolvedNames
resolveOnly ns syms = CM.intersection syms (CM.fromList (map step ns))
  where
  step n = (simpleName n,error "ModuleSystem.resolveOnly")


-- Scope Checking --------------------------------------------------------------

-- | Fully qualify all of the symbols inside of a module.  This does IO, as it
-- may end up needing to read other interface files to make a decision.
scopeCheck :: Module -> Dang (InterfaceSet, Module)
scopeCheck m = do
  logStage "module-system"
  res@(_,scm) <- runScope (withEnv m (scopeCheckModule m))
  logDebug "Module system output"
  logDebug (show scm)
  return res

-- | Check all of the identifiers in a module, requiring that they are defined
-- somewhere.
scopeCheckModule :: Module -> Scope Module
scopeCheckModule m = do
  pts <- mapM scopeCheckPrimTerm (modPrimTerms m)
  ds  <- mapM scopeCheckDecl (modDecls m)
  return m
    { modPrimTerms = pts
    , modDecls     = ds
    }

-- | Register variables as bound for the computation that is passed.
bindVars :: [Var] -> Scope a -> Scope a
bindVars vs m = do
  ro <- ask
  let locals = CM.fromList [ (simpleName v, Bound v) | v <- vs ]
  local (ro { roNames = mergeResolvedNames locals (roNames ro) }) m

-- | Check all identifiers used in a declaration.
scopeCheckDecl :: Decl -> Scope Decl
scopeCheckDecl d = bindVars (declVars d) $ do
  qt <- T.sequenceA (scopeCheckForall `fmap` declType d)
  b  <- scopeCheckTerm (declBody d)
  return d
    { declBody = b
    , declType = qt
    }

-- | Check the type associated with a primitive term.
scopeCheckPrimTerm :: PrimTerm -> Scope PrimTerm
scopeCheckPrimTerm pt = do
  ty <- scopeCheckForall (primTermType pt)
  return pt { primTermType = ty }

-- | Check all identifiers used in a term.
scopeCheckTerm :: Term -> Scope Term
scopeCheckTerm t = case t of
  Lit _    -> return t
  Prim _   -> return t
  Abs vs b -> Abs vs `fmap` bindVars vs (scopeCheckTerm b)
  Let ds b -> bindVars (map declName ds)
       (Let `fmap` mapM scopeCheckDecl ds `ap` scopeCheckTerm b)
  App f xs -> App `fmap` scopeCheckTerm f `ap` mapM scopeCheckTerm xs
  Global n -> resolveTerm n
  Local n  -> resolveTerm (simpleName n) -- the parser doesn't parse these

-- | Check the underlying type in a quantified type.
scopeCheckForall :: Forall Type -> Scope (Forall Type)
scopeCheckForall (Forall ps ty) = Forall ps `fmap` scopeCheckType ty

-- | Check all identifiers used in a type.
scopeCheckType :: Type -> Scope Type
scopeCheckType ty = case ty of
  TApp l r -> TApp `fmap` scopeCheckType l `ap` scopeCheckType r

  TInfix n l r ->
    TInfix `fmap` resolveType n `ap` scopeCheckType l `ap` scopeCheckType r

  TCon n -> TCon `fmap` resolveType n

  TVar{} -> return ty
  TGen{} -> return ty
