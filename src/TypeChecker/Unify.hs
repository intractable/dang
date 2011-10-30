{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternGuards #-}

module TypeChecker.Unify where

import Core.AST
import Dang.Monad
import Pretty
import TypeChecker.Types

import Control.Arrow (second)
import Control.Monad (unless,guard)
import Data.Typeable (Typeable)
import MonadLib (ExceptionM)
import qualified Data.Set as Set
import qualified Data.Map as Map


-- Substitution ----------------------------------------------------------------

data Subst = Subst
  { substUnbound :: Map.Map Index Type
  , substBound   :: Map.Map Index Type
  } deriving (Show)

-- | Lookup a variable index in a substitution.
lookupGen :: Index -> Subst -> Maybe Type
lookupGen i = Map.lookup i . substBound

-- | Lookup a variable index in a substitution.
lookupVar :: Index -> Subst -> Maybe Type
lookupVar i = Map.lookup i . substUnbound

-- | The empty substitution.
emptySubst :: Subst
emptySubst  = Subst
  { substUnbound = Map.empty
  , substBound   = Map.empty
  }

-- | Generate a singleton generic substitution.
genSubst :: Index -> Type -> Subst
genSubst v ty = emptySubst { substBound = Map.singleton v ty }

-- | Generate a singleton variable substitution.
varSubst :: Index -> Type -> Subst
varSubst v ty = emptySubst { substUnbound = Map.singleton v ty }

-- | Generate a substitution on unbound variables.
unboundSubst :: [(Index,Type)] -> Subst
unboundSubst u = emptySubst { substUnbound = Map.fromList u }

-- | Generate a substitution on bound variables.
boundSubst :: [(Index,Type)] -> Subst
boundSubst u = emptySubst { substBound = Map.fromList u }

-- | Compose two substitutions.
(@@) :: Subst -> Subst -> Subst
s1 @@ s2 = Subst
  { substBound = Map.map (apply s1) (substBound s2)
      `Map.union` substBound s1
  , substUnbound = Map.map (apply s1) (substUnbound s2)
      `Map.union` substUnbound s1
  }


-- Type Interface --------------------------------------------------------------

apply :: Types a => Subst -> a -> a
apply  = apply' 0


class Types a where
  apply'   :: Int -> Subst -> a -> a
  typeVars :: a -> Set.Set TParam

instance Types a => Types [a] where
  apply' b u = map (apply' b u)
  typeVars  = Set.unions . map typeVars

instance Types Type where
  apply' b u ty = case ty of
    TApp f x     -> TApp (apply' b u f) (apply' b u x)
    TInfix n l r -> TInfix n (apply' b u l) (apply' b u r)
    TVar p       -> apply'TVar b u p
    TCon{}       -> ty

  typeVars ty = case ty of
    TApp f x     -> typeVars f `Set.union` typeVars x
    TInfix _ l r -> typeVars l `Set.union` typeVars r
    TVar tv      -> typeVarsTVar tv
    TCon{}       -> Set.empty

apply'TVar :: Int -> Subst -> TVar -> Type
apply'TVar b u tv = case tv of

  -- when an unbound variable is found, apply the substitution without adjusting
  -- the parameter index.
  UVar p -> process (lookupVar (paramIndex p) u)

  -- when a bound variable is found, make sure that it is reachable from a
  -- quantifier outside any that may have been crossed, and then adjust its
  -- index to be the same as the outer most quantifier.
  GVar p -> process $ do
    let ix = paramIndex p
    guard (ix >= b)
    lookupGen (ix - b) u

  where
  process         = maybe (TVar tv) (mapTVar adjust)
  adjust (GVar p) = GVar p { paramIndex = paramIndex p + b }
  adjust uv       = uv

typeVarsTVar :: TVar -> Set.Set TParam
typeVarsTVar (UVar p) = Set.singleton p
typeVarsTVar _        = Set.empty

genVarsTVar :: TVar -> Set.Set TParam
genVarsTVar (GVar p) = Set.singleton p
genVarsTVar _        = Set.empty

instance Types Decl where
  apply' b s d = d { declBody = apply' b s (declBody d) }
  typeVars  = typeVars . declBody

instance Types a => Types (Forall a) where
  apply' b u (Forall ps a) = Forall ps (apply' (b + length ps) u a)
  typeVars (Forall _ a)    = typeVars a

instance Types Match where
  apply' b s m = case m of
    MTerm t ty -> MTerm (apply' b s t) (apply' b s ty)
    MPat p m'  -> MPat  (apply' b s p) (apply' b s m')

  typeVars m = case m of
    MTerm t ty -> typeVars t `Set.union` typeVars ty
    MPat p m'  -> typeVars p `Set.union` typeVars m'

instance Types Pat where
  apply' b s p = case p of
    PWildcard ty -> PWildcard (apply' b s ty)
    PVar v ty    -> PVar v    (apply' b s ty)

  typeVars p = case p of
    PWildcard ty -> typeVars ty
    PVar _ ty    -> typeVars ty

instance Types Term where
  apply' b s tm = case tm of
    AppT f ts -> AppT (apply' b s f)  (apply' b s ts)
    App t ts  -> App  (apply' b s t)  (apply' b s ts)
    Let ds e  -> Let  (apply' b s ds) (apply' b s e)
    Global qn -> Global qn
    Local n   -> Local n
    Lit lit   -> Lit lit

  typeVars tm = case tm of
    AppT f ts -> typeVars f  `Set.union` typeVars ts
    App t ts  -> typeVars t  `Set.union` typeVars ts
    Let ds e  -> typeVars ds `Set.union` typeVars e
    Global _  -> Set.empty
    Local _   -> Set.empty
    Lit _     -> Set.empty


-- Unification -----------------------------------------------------------------

data UnifyError
  = UnifyError Type Type
  | UnifyOccursCheck TParam Type
  | UnifyGeneric String
    deriving (Show,Typeable)

instance Exception UnifyError

unifyError :: ExceptionM m SomeException => String -> m a
unifyError  = raiseE . UnifyGeneric

-- | Generate the most-general unifier for two types.
mgu :: ExceptionM m SomeException => Type -> Type -> m Subst
mgu a b = case (a,b) of

  -- type application
  (TApp f x, TApp g y) -> do
    sf <- mgu f g
    sx <- mgu (apply sf x) (apply sf y)
    return (sf @@ sx)

  -- infix type constructor application
  (TInfix n l r, TInfix m x y) -> do
    unless (n == m) $ unifyError $ concat
      [ "Expected infix constructor ``", pretty n
      , "'', got ``", pretty m, "''" ]
    sl <- mgu l x
    sr <- mgu (apply sl r) (apply sl y)
    return (sl @@ sr)

  (TVar (UVar p), r) -> varBind p r
  (l, TVar (UVar p)) -> varBind p l

  -- constructors
  (TCon l, TCon r) | l == r -> return emptySubst

  _ -> raiseE (UnifyError a b)


-- | Generate a substitution that unifies a variable with a type.
--
-- XXX should this do a kind check in addition to an occurs check?
varBind :: ExceptionM m SomeException => TParam -> Type -> m Subst
varBind p ty
  | Just p' <- destUVar ty, p == p' = return emptySubst
  | occursCheck p ty                = raiseE (UnifyOccursCheck p ty)
  | otherwise                       = return (varSubst (paramIndex p) ty)


occursCheck :: TParam -> Type -> Bool
occursCheck p = Set.member p . typeVars


-- Instantiation ---------------------------------------------------------------

inst :: Types t => [Type] -> t -> t
inst ts = apply (emptySubst { substBound = Map.fromList (zip [0 ..] ts) })


-- Quantification --------------------------------------------------------------

-- | Generalize type variables.
quantify :: Types t => [TParam] -> t -> Forall t
quantify ps t = Forall ps' (apply u t)
  where
  vs         = Set.toList (typeVars t `Set.intersection` Set.fromList ps)
  subst      = zipWith mkGen [0..] vs
  mkGen ix v = (paramIndex v, v { paramIndex = ix })
  (_,ps')    = unzip subst
  u          = unboundSubst (map (second gvar) subst)


quantifyAll :: Types t => t -> Forall t
quantifyAll ty = quantify (Set.toList (typeVars ty)) ty

{-
-- | Quantify the type parameters provided, but extend an existing quantifier
-- instead of generating a new one.
quantify' :: Types t => [TParam] -> Forall t -> Forall t
quantify' ps (Forall ps0 t) = Forall (ps0 ++ ps') t'
  where
  i        = length ps0
  (ps',t') = quantifyAux i ps t

quantifyAux :: Types t => Int -> [TParam] -> t -> ([TParam],t)
quantifyAux i ps t = (vs',apply s t)
  where
  vs        = [ v | v <- Set.toList (typeVars t), v `elem` ps ]
  u         = zipWith mkGen [i ..] vs
  mkGen n p = (paramIndex p, p { paramIndex = n })
  (_,vs')   = unzip u
  s         = Subst (map (second (TVar . GVar)) u)
  -}
