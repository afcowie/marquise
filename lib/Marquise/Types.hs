--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}

-- Our Base/BaseControl instances are simple enough to assert that
-- that they are decidable, monad-control needs this too.
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_HADDOCK hide, prune #-}

-- Hide warnings for the deprecated ErrorT transformer:
{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}

module Marquise.Types
    ( -- * Data
      SpoolName(..)
    , SpoolFiles(..)
    , TimeStamp(..)
    , SimplePoint(..), ExtendedPoint(..)

      -- * Results
    , Result, wrapResult, unwrapResult

      -- * Errors
    , Marquise
    , unwrap, unMarquise
    , MarquiseErrorType(..)
    , catchSyncIO, catchTryIO, catchMarquiseP
    , RecoverInfo(..), Info
) where

import           Control.Applicative
import           Control.Monad.Base
import           Control.Monad.Error
import           Control.Monad.Morph
import           Control.Monad.Trans.Control
import           Control.Monad.Trans.Either
import           Control.Monad.Trans.State.Strict
import           Control.Error.Util
import           Control.Exception (IOException, SomeException)
import           Data.HashSet (HashSet)
import qualified Data.HashSet as HS
import           Data.Either.Combinators
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import           Data.Word (Word64)
import           Data.Monoid
import           Pipes
import qualified Pipes.Lift as P

import           Vaultaire.Types


-- | A NameSpace implies a certain amount of Marquise server-side state. This
-- state being the Marquise server's authentication and origin configuration.
newtype SpoolName = SpoolName { unSpoolName :: String }
  deriving (Eq, Show)

-- | SpoolFiles simple wraps around two file paths.
-- One for queuing points updates, one for queuing contents updates
data SpoolFiles = SpoolFiles { pointsSpoolFile   :: FilePath
                             , contentsSpoolFile :: FilePath }
  deriving (Eq, Show)

-- | SimplePoints are simply wrapped packets for Vaultaire
-- Each consists of 24 bytes:
-- An 8 byte Address
-- An 8 byte Timestamp (nanoseconds since Unix epoch)
-- An 8 byte Payload
data SimplePoint = SimplePoint { simpleAddress :: Address
                               , simpleTime    :: TimeStamp
                               , simplePayload :: Word64 }
  deriving Show


-- | ExtendedPoints are simply wrapped packets for Vaultaire
-- Each consists of 16 + 'length' bytes:
-- An 8 byte Address
-- An 8 byte Time (in nanoseconds since Unix epoch)
-- A 'length' byte Payload
-- On the wire their equivalent representation takes up
-- 24 + 'length' bytes with format:
-- 8 byte Address, 8 byte Time, 8 byte Length, Payload
data ExtendedPoint = ExtendedPoint { extendedAddress :: Address
                                   , extendedTime    :: TimeStamp
                                   , extendedPayload :: ByteString }
  deriving Show


-- Result ----------------------------------------------------------------------

-- | A type-level fixed point.
newtype Fix f         = Mu      { unroll :: (f (Fix f)) }

-- | The query output type with the return type left untied.
data    ResultF a m r = ResultF { resume :: Producer a m r }

-- | The query output type with itself as the return type.
newtype Result a m    = Result  { resultf :: Fix (ResultF a m) }

wrapResult   = Result . Mu     . ResultF
unwrapResult = resume . unroll . resultf


-- Errors ----------------------------------------------------------------------

-- | Handles everything that can fail so we don't ever just crash from an exception
--   but always provide opportunities to recover.
--
--   *NOTE*
--   This is a newtype because we want to define our own @MonadTransControl@ instance
--   that exposes the errors to be unwrapped and restored manually.
--   See @Marquise.Classes@
--
newtype Marquise m a = Marquise { marquise :: ErrorT MarquiseErrorType (StateT Info m) a }
  deriving ( Functor, Applicative, Monad
           , MonadError MarquiseErrorType, MonadIO
           ) --, MonadTrans, MFunctor, MMonad)

instance MonadTrans Marquise where
  lift = lift

instance MFunctor Marquise where
  hoist = hoist

-- | This is needed for @squash@ to define a generic implementation for @withConnectionT@
--   in terms of @withConnection@. See @Marquise.Classes@.
--
instance MMonad Marquise where
  embed f m = Marquise $ ErrorT $ StateT $ \s -> do
    (a, s1) <- runStateT (runErrorT $ marquise $ f (runStateT (runErrorT $ marquise m) s)) s
    return $ case a of
      Left e              -> (Left e,  s1)            -- there is only one state and one error
      Right (Left e, s2)  -> (Left e,  mappend s2 s1) -- the failure takes precedence as error, merge the 2 states
      Right (Right x, s2) -> (Right x, mappend s2 s1) -- no error, merge the 2 states
  {-# INLINE embed #-}

instance MonadTransControl Marquise where
  data StT Marquise a = StMarquise { unStMarquise :: (Either MarquiseErrorType a, Info) }
  liftWith f = Marquise $ ErrorT $ StateT $ \s ->
    liftM (, s)                                                            -- rewrap state
          (liftM return                                                    -- rewrap error
                 (f $ \t -> liftM StMarquise
                                  (runStateT (runErrorT $ marquise t) s))) -- unwrap error and state
  restoreT = Marquise . ErrorT . StateT . const . liftM unStMarquise
  {-# INLINE liftWith #-}
  {-# INLINE restoreT #-}

deriving instance MonadBase b m => MonadBase b (Marquise m)

instance MonadBaseControl b m => MonadBaseControl b (Marquise m) where
  newtype StM (Marquise m) a = StMMarquise { unStMMarquise :: ComposeSt Marquise m a}
  liftBaseWith = defaultLiftBaseWith StMMarquise
  restoreM     = defaultRestoreM   unStMMarquise
  {-# INLINE liftBaseWith #-}
  {-# INLINE restoreM #-}

-- | Unwrap the insides of a @Marquise@ monad and keep them in the @StT@ from
--   @monad-control@, so we need to @restoreT@ manually.
unwrap :: Functor m => Marquise m a -> m (StT Marquise a)
unwrap = fmap StMarquise . flip runStateT [] . runErrorT . marquise

unMarquise :: Marquise m a -> m (Either MarquiseErrorType a, Info)
unMarquise = flip runStateT [] . runErrorT . marquise

-- | Information to recover from the failure of an operation.
--   it is up to the operation to decide what state it needs to recover.
--
data RecoverInfo
 = EnumOrigin { origin :: Origin, enumerated :: HashSet Address }
 | ReadPoints { origin :: Origin, addr :: Address, latest :: TimeStamp }

-- todo make this a set
type Info = [RecoverInfo]

instance Show RecoverInfo where
  show (EnumOrigin o e)   = concat ["failure state: got ", show (HS.size e), " addresses from ", show o]
  show (ReadPoints o a t) = concat ["failure state: read from ", show o, " ", show a, " last point was ", show t]

-- | All possible errors in a Marquise program.
--
data MarquiseErrorType
 = InvalidSpoolName   String
 | InvalidOrigin      Origin
 | Timeout                          RecoverInfo -- ^ timeout connecting to backend
 | MalformedResponse  String                    -- ^ unexected response from backend
 | VaultaireException SomeException             -- ^ handles all backend exceptions
 | ZMQException       SomeException RecoverInfo -- ^ handles all zmq exceptions
 | IOException        IOException               -- ^ handles all IO exceptions
 | Other              String                    -- ^ needed for the @Error@ instance until pipes move to @Except@

instance Show MarquiseErrorType where
  show (InvalidSpoolName s)     = "marquise: invalid spool name: "  ++ s
  show (InvalidOrigin x)        = "marquise: invalid origin: "      ++ (B8.unpack $ unOrigin x)
  show (Timeout _)              = "marquise: timeout"
  show (MalformedResponse s)    = "marquise: unexpected response: " ++ s
  show (VaultaireException e)   = "marquise: vaultaire error: "     ++ show e
  show (ZMQException       e _) = "marquise: ZMQ error: "           ++ show e
  show (IOException        e)   = "marquise: IO error: "            ++ show e
  show (Other s)                = "marquise: error: "               ++ s

instance Error MarquiseErrorType where
  noMsg = Other "unknown"

-- | Catch a Marquise error inside a pipe
catchMarquiseP
  :: (Monad m)
  => Proxy a' a b' b (Marquise m) r
  -> (MarquiseErrorType -> Proxy a' a b' b (Marquise m) r)
  -> Proxy a' a b' b (Marquise m) r
catchMarquiseP act handler
  = hoist Marquise $ P.catchError (hoist marquise act) (hoist marquise . handler)

-- | Catch all synchorous IO exceptions and wrap them in @ErrorT@
catchSyncIO :: (SomeException -> MarquiseErrorType) -> IO a -> Marquise IO a
catchSyncIO f = Marquise . ErrorT . fmap (mapLeft f) . runEitherT . syncIO

-- | Catch only @IOException@s
catchTryIO  :: IO a -> Marquise IO a
catchTryIO = Marquise . ErrorT . fmap (mapLeft IOException) . runEitherT . tryIO
