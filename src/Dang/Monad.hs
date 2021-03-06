{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Dang.Monad (
    Dang
  , runDang

  , Options(..)
  , DebugOpts(..)
  , getOptions
  , Verbosity
  , displayHelp
  , whenDebugOpt

  , Action(..)
  , actionSources

  , raiseE
  , catchE
  , catchJustE

  , io

  , Exception(..)
  , SomeException()
  ) where

import Control.Applicative (Applicative)
import Control.Exception (Exception(..),SomeException)
import Control.Monad.Fix (MonadFix)
import Data.List (partition)
import Data.Typeable (Typeable)
import MonadLib
import System.Console.GetOpt
import System.Environment (getArgs, getProgName)
import System.Exit (exitSuccess,exitFailure)
import System.FilePath (takeExtension)
import qualified Control.Exception as E


-- Errors ----------------------------------------------------------------------

data DangError = DangError String
    deriving (Show,Typeable)

instance Exception DangError


-- Environment Configuration ---------------------------------------------------

data Options = Options
  { optKeepTempFiles :: Bool
  , optAction        :: Action
  , optVerbosity     :: Verbosity
  , optCompileOnly   :: Bool
  , optDebugOpts      :: DebugOpts
  } deriving Show

defaultOptions :: Options
defaultOptions  = Options
  { optKeepTempFiles = False
  , optAction        = NoAction
  , optVerbosity     = 0
  , optCompileOnly   = False
  , optDebugOpts      = emptyDebugOpts
  }

data Action
  = Compile [FilePath]
  | Link [FilePath] [FilePath]
  | NoAction
    deriving Show

actionSources :: Action -> [FilePath]
actionSources (Compile fs) = fs
actionSources (Link fs _)  = fs
actionSources NoAction     = []

type Verbosity = Int

type Option = Options -> IO Options

parseOptions :: [String] -> IO Options
parseOptions args =
  case getOpt Permute options args of
    (os,fs,[]) -> buildOptions os fs
    (_,_,errs) -> do
      displayHelp errs
      exitFailure

buildOptions :: [Option] -> [String] -> IO Options
buildOptions os fs = do
  opts <- foldM (flip id) defaultOptions os
  return opts { optAction = inferAction opts fs }

inferAction :: Options -> [String] -> Action
inferAction opts fs
  | optCompileOnly opts = Compile sources
  | otherwise           = Link sources objs
  where
  (sources,objs) = partition (\f -> takeExtension f == ".dg") fs

displayHelp :: [String] -> IO ()
displayHelp errs = do
  prog <- getProgName
  let banner = unlines (errs ++ ["Usage: " ++ prog ++ " [options] source"])
  putStr (usageInfo banner options)

options :: [OptDescr Option]
options  =
  [ Option "h" ["help"] (NoArg handleHelp)
    "Display this message"
  , Option [] ["keep-temp-files"] (NoArg setKeepTempFiles)
    "Don't remove temp files created during compilation"
  , Option "v" ["verbosity"] (ReqArg setVerbosity "LEVEL")
    "Set the logging verbosity"
  , Option "c" [] (NoArg setCompileOnly)
    "Compile only"
  ] ++ debugOpts

handleHelp :: Option
handleHelp _ = do
  displayHelp []
  exitSuccess

setKeepTempFiles :: Option
setKeepTempFiles opts = return opts { optKeepTempFiles = True }

setVerbosity :: String -> Option
setVerbosity msg opts =
  case reads msg of
    [(v,[])] -> return opts { optVerbosity = v }
    _        -> fail ("Unable to parse verbosity from: " ++ msg)

setCompileOnly :: Option
setCompileOnly opts = return opts { optCompileOnly = True }

updateDebugOpts :: (DebugOpts -> IO DebugOpts) -> Option
updateDebugOpts k opts = do
  d <- k (optDebugOpts opts)
  return opts { optDebugOpts = d }

data DebugOpts = DebugOpts
  { dbgDumpLLVM :: Bool
  } deriving Show

emptyDebugOpts :: DebugOpts
emptyDebugOpts  = DebugOpts
  { dbgDumpLLVM = False
  }

debugOpts :: [OptDescr Option]
debugOpts  =
  [ Option "" ["dump-llvm"] (NoArg (updateDebugOpts setDumpLLVM))
    "Dump the generated LLVM assembly"
  ]

setDumpLLVM :: DebugOpts -> IO DebugOpts
setDumpLLVM opts = return opts { dbgDumpLLVM = True }


-- Monad -----------------------------------------------------------------------

newtype Dang a = Dang
  { getDang :: ReaderT Options IO a
  } deriving (Functor,Applicative,MonadFix)

instance Monad Dang where
  {-# INLINE return #-}
  return x = Dang (return x)

  {-# INLINE (>>=) #-}
  Dang m >>= f = Dang (getDang . f =<< m)

  {-# INLINE fail #-}
  fail msg = raiseE (DangError msg)

instance ReaderM Dang Options where
  ask = Dang ask

instance ExceptionM Dang SomeException where
  {-# INLINE raise #-}
  raise = io . E.throwIO

instance RunExceptionM Dang SomeException where
  {-# INLINE try #-}
  try m = do
    opts <- ask
    io (E.try (runReaderT opts (getDang m)))

instance BaseM Dang Dang where
  inBase = id

-- | Do some IO.
io :: BaseM m Dang => IO a -> m a
io  = inBase . Dang . inBase

-- | Get the operations, in a derived monad.
getOptions :: BaseM m Dang => m Options
getOptions  = inBase ask

-- | Turn a Dang operation into an IO operation, swallowing all exceptions.
runDang :: Dang a -> IO ()
runDang m = do
  args <- getArgs
  opts <- parseOptions args
  E.handle handler $ do
    _ <- runReaderT opts (getDang m)
    return ()
  where
  handler :: SomeException -> IO ()
  handler e = print e

-- | Raise an exception.
raiseE :: (ExceptionM m SomeException, Exception e) => e -> m a
raiseE  = raise . toException

-- | Catch an exception.
catchE :: (RunExceptionM m SomeException, Exception e)
       => m a -> (e -> m a) -> m a
catchE m h = do
  e <- try m
  case e of
    Left se -> maybe (raise se) h (fromException se)
    Right a -> return a

-- | Catch an exception guarded by a predicate.
catchJustE :: (RunExceptionM m SomeException, Exception e)
           => (e -> Maybe b) -> m a -> (b -> m a) -> m a
catchJustE p m h = catchE m $ \ e ->
  case p =<< fromException e of
    Just b  -> h b
    Nothing -> raiseE e

whenDebugOpt :: (BaseM m Dang) => (DebugOpts -> Bool) -> m () -> m ()
whenDebugOpt p m = do
  opts <- getOptions
  when (p (optDebugOpts opts)) m
