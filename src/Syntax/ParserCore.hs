{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Syntax.ParserCore where

import QualName
import Syntax.AST
import TypeChecker.Types
import Data.ClashMap as CM

import Control.Applicative (Applicative)
import Data.Int (Int64)
import Data.Maybe (isNothing)
import MonadLib
import qualified Data.ByteString as S
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.Map as Map


-- Lexer/Parser Monad ----------------------------------------------------------

data Position = Position
  { posOff  :: !Int
  , posLine :: !Int
  , posCol  :: !Int
  , posFile :: FilePath
  } deriving Show

initPosition :: FilePath -> Position
initPosition path = Position
  { posOff  = 0
  , posLine = 1
  , posCol  = 1
  , posFile = path
  }

movePos :: Position -> Char -> Position
movePos (Position a line col path) c =
  case c of
    '\t' -> Position (a+1) line (col+8) path
    '\n' -> Position (a+1) (line+1) 1 path
    _    -> Position (a+1) line (col+1) path

data Token
  = TReserved String
  | TConIdent String
  | TSymIdent String
  | TInt Int64
  | TEof
    deriving (Eq,Show)

data Lexeme = Lexeme
  { lexPos   :: !Position
  , lexToken :: Token
  } deriving Show

instance Eq Lexeme where
  a == b = lexToken a == lexToken b

data ErrorType
  = LexerError
  | ParserError
    deriving Show

data Error = Error ErrorType String Position deriving Show

data ParserState = ParserState
  { psInput   :: !S.ByteString
  , psChar    :: !Char
  , psPos     :: !Position
  , psLexCode :: !Int
  } deriving Show

initParserState :: FilePath -> S.ByteString -> ParserState
initParserState path bs = ParserState
  { psInput   = bs
  , psChar    = '\n'
  , psPos     = initPosition path
  , psLexCode = 0
  }

newtype Parser a = Parser
  { unParser :: WriterT [ParserError]
              (StateT ParserState (ExceptionT Error Id)) a
  } deriving (Functor,Applicative,Monad)

data ParserError
  = MultipleDefs Name
  | NoBinding Name
    deriving (Show)

instance StateM Parser ParserState where
  get = Parser   get
  set = Parser . set

instance ExceptionM Parser Error where
  raise = Parser . raise

instance RunExceptionM Parser Error where
  try m = Parser (try (unParser m))

instance WriterM Parser [ParserError] where
  put = Parser . put

instance RunWriterM Parser [ParserError] where
  collect = Parser . collect . unParser

-- | Raise an exception from the lexer.
raiseL :: String -> Parser a
raiseL msg = do
  st <- get
  raise (Error LexerError msg (psPos st))

-- | Raise an exception from the parser.
raiseP :: String -> Parser a
raiseP msg = do
  st <- get
  raise (Error ParserError msg (psPos st))

-- | Run the parser over the file given.
runParser :: FilePath -> S.ByteString -> Parser a -> Either Error a
runParser path bs m =
  case runM (unParser body) (initParserState path bs) of
    Right ((a,_),_) -> Right a
    Left err        -> Left err
  where
  body = do
    (res,errs) <- collect m
    unless (null errs) (raiseP ("definition errors: " ++ show errs))
    return res

-- | For testing parsers within ghci.
testParser :: Parser a -> String -> Either Error a
testParser p str = runParser "<interactive>" (UTF8.fromString str) p


-- Parsed Syntax ---------------------------------------------------------------

type NameMap = CM.ClashMap Name

-- | Attempt to resolve clashes with a merge operation.
mergeNamedBy :: Strategy a -> NameMap a -> NameMap a -> NameMap a
mergeNamedBy  = CM.unionWith

-- | Add an element to a name map.
addNamed :: Strategy a -> Name -> a -> NameMap a -> NameMap a
addNamed  = CM.insertWith

-- | Map over the elements of a name map.
mapNamed :: (a -> b) -> NameMap a -> NameMap b
mapNamed  = fmap

-- | Merge type and term declarations, when appropriate.
resolveTypes :: Strategy (Either (Forall Type) Decl)
resolveTypes a b = case (a,b) of
  (Right d, Left t) -> d `tryType` t
  (Left t, Right d) -> d `tryType` t
  _                 -> clash a b
  where
  tryType d t | isNothing (declType d) = ok (Right (d { declType = Just t }))
              | otherwise              = clash a b

-- | A collection of parsed declarations.  Loosely, this is a module.
data PDecls = PDecls
  { parsedDecls     :: NameMap (Either (Forall Type) Decl)
  , parsedOpens     :: [Open]
  , parsedPrimTerms :: NameMap PrimTerm
  , parsedPrimTypes :: NameMap PrimType
  } deriving (Show)

emptyPDecls :: PDecls
emptyPDecls  = PDecls
  { parsedDecls     = CM.empty
  , parsedOpens     = []
  , parsedPrimTerms = CM.empty
  , parsedPrimTypes = CM.empty
  }

mkDecl :: Decl -> PDecls
mkDecl d = emptyPDecls { parsedDecls = singleton (declName d) (Right d) }

mkTypeDecl :: Name -> Forall Type -> PDecls
mkTypeDecl n t = emptyPDecls { parsedDecls = singleton n (Left t) }

addDecl :: Decl -> PDecls -> PDecls
addDecl d ds = ds
  { parsedDecls = addNamed resolveTypes (declName d) (Right d) (parsedDecls ds)
  }

mkDecls :: [Decl] -> PDecls
mkDecls ds = emptyPDecls { parsedDecls = foldl step CM.empty ds }
  where
  step m d = addNamed resolveTypes (declName d) (Right d) m

-- | Turn a block of declarations into a block of public declarations.
publicExport :: PDecls -> PDecls
publicExport pds = pds { parsedDecls = mapNamed step (parsedDecls pds) }
  where
  step (Right d) = Right d { declExport = Public }
  step e         = e

-- | Turn a block of declarations into a block of private declarations.
privateExport :: PDecls -> PDecls
privateExport pds = pds { parsedDecls = mapNamed step (parsedDecls pds) }
  where
  step (Right d) = Right d { declExport = Private }
  step e         = e

mkOpen :: Open -> PDecls
mkOpen o = emptyPDecls { parsedOpens = [o] }

mkPrimTerm :: PrimTerm -> PDecls
mkPrimTerm d = emptyPDecls { parsedPrimTerms = singleton (primTermName d) d }

mkPrimType :: PrimType -> PDecls
mkPrimType d = emptyPDecls { parsedPrimTypes = singleton (primTypeName d) d }

-- | Merge two sets of parsed declarations.
combinePDecls :: PDecls -> PDecls -> PDecls
combinePDecls ds1 ds2 = PDecls
  { parsedDecls     = merge resolveTypes parsedDecls
  , parsedOpens     = parsedOpens ds1 ++ parsedOpens ds2
  , parsedPrimTerms = merge clash parsedPrimTerms
  , parsedPrimTypes = merge clash parsedPrimTypes
  }
  where
  merge strat prj = mergeNamedBy strat (prj ds1) (prj ds2)

resolveNamed :: NameMap a -> Parser [a]
resolveNamed nm = do
  let (oks,clashes) = CM.foldClashMap step ([],[]) nm
      step n c (as,bs) = case clashElems c of
        [a] -> (a:as,bs)
        _es -> (as,MultipleDefs n:bs)
  put clashes
  return oks

processBindings :: NameMap (Either (Forall Type) Decl) -> Parser [Decl]
processBindings ds = do
  let (oks,clashes) = CM.foldClashMap step ([],[]) ds
      step n c (as,bs) = case clashElems c of
        [Right a] -> (a:as,bs)
        [Left _t] -> (as,NoBinding n:bs)
        _es       -> (as,MultipleDefs n:bs)
  put clashes
  return oks

-- | Make a module from a set of parsed declarations, and a name.
mkModule :: QualName -> PDecls -> Parser Module
mkModule qn pds = do
  ds  <- processBindings (parsedDecls pds)
  tms <- resolveNamed (parsedPrimTerms pds)
  tys <- resolveNamed (parsedPrimTypes pds)
  return Module
    { modName      = qn
    , modOpens     = parsedOpens pds
    , modDecls     = ds
    , modPrimTerms = tms
    , modPrimTypes = tys
    }
