{
{-# OPTIONS_GHC -w #-}
module Syntax.Lexer where

import Syntax.ParserCore

import MonadLib
import qualified Codec.Binary.UTF8.Generic as UTF8
import qualified Data.ByteString           as S

}

$digit       = [0-9]
$letter      = [a-zA-Z]
$lowerletter = [a-z]
$capletter   = [A-Z]
$symbol      = [\- \> \< \: \*]

@conident  = $capletter [$letter $digit [_ \! \? \']]*
@symident  = [_ $lowerletter] [$letter $digit [_ \! \? \']]*
@operident = $symbol+

:-

-- No nested comments, currently
<0,comment> "{-" { begin comment }
<comment> {
  "-}"           { begin 0 }
  .              ;
}

<0> {

-- skip whitespace
$white+         ;
"--".*$         ;

\\              { reserved }
"="             { reserved }
"("             { reserved }
")"             { reserved }
"let"           { reserved }
"in"            { reserved }
"{"             { reserved }
"}"             { reserved }
";"             { reserved }
","             { reserved }
"."             { reserved }
"=>"            { reserved }

"module"        { reserved }
"where"         { reserved }
"open"          { reserved }
"as"            { reserved }
"hiding"        { reserved }
"public"        { reserved }
"private"       { reserved }
"forall"        { reserved }
"primitive"     { reserved }
"type"          { reserved }

@conident       { emitS TConIdent     }
@symident       { emitS TSymIdent     }
@operident      { emitS TOperIdent    }
$digit+         { emitS (TInt . read) }
}

{
type AlexAction result = AlexInput -> Int -> result

-- | Emit a token from the lexer
emitT :: Token -> AlexAction (Parser Lexeme)
emitT tok (pos,_,_) _ = return $! Lexeme
  { lexPos   = pos
  , lexToken = tok
  }

emitS :: (String -> Token) -> AlexAction (Parser Lexeme)
emitS mk (pos,c,bs) len = return $! Lexeme
  { lexPos   = pos
  , lexToken = mk (UTF8.toString (S.take len bs))
  }

reserved :: AlexAction (Parser Lexeme)
reserved  = emitS TReserved

scan :: Parser Lexeme
scan  = do
  inp@(pos,_,_) <- alexGetInput
  sc            <- alexGetStartCode
  case alexScan inp sc of
    AlexEOF -> return $! Lexeme
      { lexPos   = pos
      , lexToken = TEof
      }

    AlexError inp' -> alexError "Lexical error"

    AlexSkip inp' len -> do
      alexSetInput inp'
      scan

    AlexToken inp' len action -> do
      alexSetInput inp'
      action inp len

type AlexInput = (Position,Char,S.ByteString)

alexGetInput :: Parser AlexInput
alexGetInput  = do
  s <- get
  return (psPos s, psChar s, psInput s)

alexSetInput :: AlexInput -> Parser ()
alexSetInput (pos,c,bs) = do
  s <- get
  set $! s
    { psPos   = pos
    , psChar  = c
    , psInput = bs
    }

alexGetChar :: AlexInput -> Maybe (Char,AlexInput)
alexGetChar (p,_,bs) = do
  (c,bs') <- UTF8.uncons bs
  return (c, (movePos p c, c, bs'))

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar (_,c,_) = c

alexError :: String -> Parser a
alexError  = raiseL

alexGetStartCode :: Parser Int
alexGetStartCode  = psLexCode `fmap` get

alexSetStartCode :: Int -> Parser ()
alexSetStartCode code = do
  s <- get
  set $! s { psLexCode = code }

begin code _ _ = alexSetStartCode code >> scan


-- | For testing the lexer within ghci.
testLexer :: Parser [Lexeme]
testLexer  = do
  lex <- scan
  if lexToken lex == TEof
    then return []
    else (lex :) `fmap` testLexer

}

