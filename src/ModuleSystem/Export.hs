{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}

module ModuleSystem.Export where

import Pretty (Pretty(..),Doc,text,isEmpty,empty,nest,($$))
import Traversal (Data,Typeable)

import Data.Function (on)
import Data.List (groupBy)
import Language.Haskell.TH.Syntax (Lift(..))


-- Export Specifications -------------------------------------------------------

data Export = Public | Private
    deriving (Eq,Show,Ord,Data,Typeable)

instance Pretty Export where
  pp _ Public  = text "public"
  pp _ Private = text "private"

instance Lift Export where
  lift ex = case ex of
    Public  -> [| Public  |]
    Private -> [| Private |]

class Exported a where
  exportSpec :: a -> Export

instance Exported Export where
  exportSpec = id

isExported :: Exported a => a -> Bool
isExported a = case exportSpec a of
  Public -> True
  _      -> False

groupByExport :: Exported a => [a] -> [[a]]
groupByExport  = groupBy ((==) `on` exportSpec)

ppPublic :: Doc -> Doc
ppPublic d | isEmpty d = empty
           | otherwise = text "public" $$ nest 2 d

ppPrivate :: Doc -> Doc
ppPrivate d | isEmpty d = empty
            | otherwise = text "private" $$ nest 2 d
