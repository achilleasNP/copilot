--------------------------------------------------------------------------------
-- Copyright © 2011 National Institute of Aerospace / Galois, Inc.
--------------------------------------------------------------------------------

-- |

{-# LANGUAGE Rank2Types #-}

module Copilot.Language.Reify
  ( reify
  ) where

import Data.IntMap (IntMap)
import qualified Data.IntMap as M
import Data.IORef
import Copilot.Core (Spec (..), Typed, Id, typeOf)
import qualified Copilot.Core as Core
import Copilot.Language.Stream (Stream (..), Trigger (..), TriggerArg (..))
import Copilot.Language.Reify.DynStableName

--------------------------------------------------------------------------------

newtype WrapExpr α = WrapExpr
  { unWrapExpr :: forall η . Core.Expr η => η α }

wrapExpr :: (forall η . Core.Expr η => η α) -> WrapExpr α
wrapExpr = WrapExpr

--------------------------------------------------------------------------------

reify :: [Trigger] -> IO Spec
reify triggers =
  do
    refCount   <- newIORef 0
    refVisited <- newIORef M.empty
    refMap     <- newIORef []
    xs <- mapM (mkTrigger refCount refVisited refMap) triggers
    ys <- readIORef refMap
    return $ Spec (reverse ys) xs

--------------------------------------------------------------------------------

{-# INLINE mkTrigger #-}
mkTrigger
  :: IORef Int
  -> IORef (IntMap [(StableName, Int)])
  -> IORef [Core.Stream]
  -> Trigger
  -> IO Core.Trigger
mkTrigger refCount refVisited refMap (Trigger name guard args) =
  do
    w1 <- mkExpr refCount refVisited refMap guard
    args' <- mapM mkTriggerArg args
    return $ Core.Trigger name (unWrapExpr w1) args'

  where

  mkTriggerArg :: TriggerArg -> IO Core.TriggerArg
  mkTriggerArg (TriggerArg e) =
    do
      w <- mkExpr refCount refVisited refMap e
      return $ Core.TriggerArg (unWrapExpr w) typeOf

--------------------------------------------------------------------------------

mkExpr
  :: (Show α, Typed α)
  => IORef Int
  -> IORef (IntMap [(StableName, Int)])
  -> IORef [Core.Stream]
  -> Stream α
  -> IO (WrapExpr α)
mkExpr refCount refVisited refMap e0 =
  case e0 of
    Append _ _ _    -> do s <- mkStream refCount refVisited refMap e0
                          return $ wrapExpr $ Core.drop typeOf 0 s
    Const x         -> return $ wrapExpr $ Core.const typeOf x
    Drop k e1       -> case e1 of
                         Append _ _ _ ->
                           do
                             s <- mkStream refCount refVisited refMap e1
                             return $ wrapExpr $ Core.drop typeOf k s
                         _ -> error "dfs: Drop" -- !!! This needs to be fixed !!!
    Extern cs       -> return $ wrapExpr $ Core.extern typeOf cs
    Op1 op e        -> do
                         w <- mkExpr refCount refVisited refMap e
                         return $ wrapExpr $ Core.op1 op (unWrapExpr w)
    Op2 op e1 e2    -> do
                         w1 <- mkExpr refCount refVisited refMap e1
                         w2 <- mkExpr refCount refVisited refMap e2
                         return $ wrapExpr $ Core.op2 op
                           (unWrapExpr w1) (unWrapExpr w2)
    Op3 op e1 e2 e3 -> do
                         w1 <- mkExpr refCount refVisited refMap e1
                         w2 <- mkExpr refCount refVisited refMap e2
                         w3 <- mkExpr refCount refVisited refMap e3
                         return $ wrapExpr $ Core.op3 op
                           (unWrapExpr w1) (unWrapExpr w2) (unWrapExpr w3)

--------------------------------------------------------------------------------

{-# INLINE mkStream #-}
mkStream
  :: (Show α, Typed α)
  => IORef Int
  -> IORef (IntMap [(StableName, Int)])
  -> IORef [Core.Stream]
  -> Stream α
  -> IO Id
mkStream refCount refVisited refMap e0 =
  do
    stn <- makeStableName e0
    let Append buf _ e = e0 -- avoids warning
    mk <- haveVisited stn
    case mk of
      Just id_ -> return id_
      Nothing  -> addToVisited stn buf e

  where

  {-# INLINE haveVisited #-}
  haveVisited :: StableName -> IO (Maybe Int)
  haveVisited stn =
    do
      tab <- readIORef refVisited
      return (M.lookup (hashStableName stn) tab >>= lookup stn)

  {-# INLINE addToVisited #-}
  addToVisited
    :: (Show α, Typed α)
    => StableName
    -> [α]
    -> Stream α
    -> IO Id
  addToVisited stn buf e =
    do
      id_ <- atomicModifyIORef refCount $ \ n -> (succ n, n)
      modifyIORef refVisited $
        M.insertWith (++) (hashStableName stn) [(stn, id_)]
      w <- mkExpr refCount refVisited refMap e
      modifyIORef refMap $
        (:) (Core.Stream id_ buf Nothing (unWrapExpr w) typeOf)
      return id_

--------------------------------------------------------------------------------