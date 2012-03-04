{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}

module QualName where

import Pretty
import Traversal (Data,Typeable)
import Utils (splitLast)

import Control.Applicative ((<$>),(<*>))
import Control.Monad (guard)
import Data.Char (isSpace)
import Data.Serialize (Get,Putter,Serialize(get,put),getWord8,putWord8)
import Numeric (showHex)
import Language.Haskell.TH.Syntax (Lift(..),liftString,Exp(ListE))


type Name = String

type Namespace = [String]

data QualName
  = QualName Namespace Name
  | PrimName Namespace Name
    deriving (Ord,Eq,Show,Data,Typeable)

instance Lift QualName where
  lift qn = case qn of
    QualName ps n ->
      [| QualName $(ListE `fmap` mapM liftString ps) $(liftString n) |]
    PrimName ps n ->
      [| PrimName $(ListE `fmap` mapM liftString ps) $(liftString n) |]

instance Pretty QualName where
  pp _ (QualName ns n) = ppWithNamespace ns (text n)
  pp _ (PrimName _  n) = text n -- XXX how should the namespace be used here?
  ppList _             = brackets . commas . map ppr

ppWithNamespace :: Namespace -> Doc -> Doc
ppWithNamespace [] d = d
ppWithNamespace ns d = dots (map text ns) <> dot <> d

instance Serialize QualName where
  get = getQualName
  put = putQualName

putName :: Putter Name
putName  = put

getName :: Get Name
getName  = get

getQualName :: Get QualName
getQualName  = getWord8 >>= \tag ->
  case tag of
    0 -> QualName <$> get <*> get
    1 -> PrimName <$> get <*> get
    _ -> fail ("QualName: unknown tag 0x" ++ showHex tag "")

putQualName :: Putter QualName
putQualName (QualName ns n) = putWord8 0 >> put ns >> put n
putQualName (PrimName ns n) = putWord8 1 >> put ns >> put n

-- | Make a qualified name.
qualName :: Namespace -> Name -> QualName
qualName  = QualName

-- | Make a simple name.
simpleName :: Name -> QualName
simpleName  = QualName []

isSimpleName :: QualName -> Bool
isSimpleName (QualName ns _) = null ns
isSimpleName _               = False

-- | Make a primitive name.
primName :: Namespace -> Name -> QualName
primName  = PrimName

-- | Get the prefix of a qualified name.
qualPrefix :: QualName -> Namespace
qualPrefix (QualName ps _) = ps
qualPrefix (PrimName ps _) = ps

-- | Get the name part of a qualified name
qualSymbol :: QualName -> Name
qualSymbol (QualName _ n) = n
qualSymbol (PrimName _ n) = n

-- | Modify the symbol in a qualified name.
mapSymbol :: (Name -> Name) -> (QualName -> QualName)
mapSymbol f (QualName ns n) = QualName ns (f n)
mapSymbol f (PrimName ns n) = PrimName ns (f n)

-- | Get the module name associated with a qualified name.
qualModule :: QualName -> Maybe QualName
qualModule qn = do
  let pfx = qualPrefix qn
  guard (not (null pfx))
  (ns,n) <- splitLast pfx
  return (QualName ns n)

-- | Mangle a qualified name into one that is suitable for code generation.
mangle :: QualName -> String
mangle qn = foldr prefix (qualSymbol qn) (qualPrefix qn)
  where
  prefix pfx rest = rename pfx ++ "_" ++ rest
  rename          = concatMap $ \c ->
    case c of
      '_'           -> "__"
      '.'           -> "_"
      _ | isSpace c -> []
        | otherwise -> [c]

-- | The namespace generated by a qualified name.
qualNamespace :: QualName -> Namespace
qualNamespace (QualName ps n) = ps ++ [n]
qualNamespace (PrimName ps n) = ps ++ [n]

-- | Modify the namespace of a qualified name.
changeNamespace :: Namespace -> QualName -> QualName
changeNamespace ns (QualName _ n) = QualName ns n
changeNamespace ns (PrimName _ n) = PrimName ns n
