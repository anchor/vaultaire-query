{-# LANGUAGE DeriveGeneric, RecordWildCards, TupleSections #-}

module Eval where

import           Control.Applicative
import           Control.Monad.Except
import           Data.Either.Combinators
import           Data.Monoid
import qualified Data.ByteString.Char8 as B8
import           Network.URI
import           Pipes
import qualified Pipes.ByteString as PB
import qualified Pipes.Csv as PC
import qualified Pipes.Prelude as P
import           Pipes.Safe
import qualified System.IO as IO
import           System.Directory
import           System.FilePath

import           Vaultaire.Query
import           Vaultaire.Types
import           Chevalier.Client
import           Parse

evalAlign :: Policy -> FilePath
          -> Source -> Source -> IO ()
evalAlign pol outfile sauce1 sauce2 = do
  (sd, s1) <- msnd Select <$> retrieve pol sauce1
  (_,  s2) <- msnd Select <$> retrieve pol sauce2
  out outfile $ enumerate $ align (sd, s1) s2
  where msnd f (x,y) = (x, f y)

evalExport :: Policy -> FilePath
           -> URI -> Origin -> TimeStamp -> TimeStamp -> IO ()
evalExport pol outdir u org start end = do
  runSafeT $ runEffect
           $ enumerateOrigin pol u org >-> fetchAddress
  where fetchAddress = forever $ do
          (addr, sd) <- await
          let addrdir = concat [outdir, "/", show addr, escape $ B8.unpack $ toWire sd]
          let pfile   = concat [addrdir, "/points"]
          h <- liftIO $ do
                createDirectoryIfMissing False addrdir
                B8.appendFile (addrdir ++ "/sd") (toWire sd)
                logInfo $ "Reading points from address " ++ show addr
                IO.openFile pfile IO.WriteMode
          runEffect $   readSimplePoints pol u addr start end org
                    >-> PC.encode
                    >-> PB.toHandle h
          liftIO $ IO.hClose h
        escape = map (\c -> if isPathSeparator c then '_' else c)

retrieve :: MonadSafe m => Policy -> Source -> IO (SourceDict, Producer SimplePoint m ())
retrieve _ (File _ p sd) = do
  dict <- liftIO $ IO.readFile sd
  h    <- liftIO $ IO.openFile p IO.ReadMode
  return $ ( fromRight mempty $ fromWire $ B8.pack dict
           , PC.decode PC.NoHeader (PB.fromHandle h) >-> hush)
  where hush = P.filter isRight >-> P.map fromRight'

retrieve pol (Vault u org addr start end) = do
  sd <- maybe mempty id <$> getSourceDict org addr
  return (sd, readSimplePoints pol u addr start end org)

out :: FilePath -> Producer SimplePoint (SafeT IO) () -> IO ()
out f p = do
  h <- IO.openFile f IO.WriteMode
  IO.hSetBuffering h IO.NoBuffering
  runSafeT $ runEffect $ p >-> PC.encode >-> PB.toHandle h

-- TODO add logging to this CLI tool
logInfo :: String -> IO ()
logInfo = putStrLn
