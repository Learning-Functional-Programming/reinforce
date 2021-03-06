{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Reinforce.Agents.QTable where

import Control.Monad.Reader.Class
import Control.Monad.RWS.Class
import Control.Monad.IO.Class
import Control.Monad.Writer.Class
import Control.Monad.State.Class
import Control.Monad.Trans
import Control.Monad.Trans.RWS (RWST, runRWST)
import Data.Hashable
import Data.Maybe (fromMaybe)
import Lens.Micro.Platform


import Control.MonadEnv as Env
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Control.MonadMWCRandom
import Data.Logger
import Reinforce.Algorithms.Internal (TDLearning(..), RLParams(..))
import Reinforce.Policy.EpsilonGreedy


type EnvC m    = (MonadIO m, MonadMWCRandom m)
type ActionC a = (Ord a, Hashable a, Enum a, Bounded a)
type RewardC r = (Variate r, Ord r, Enum r, Num r)
type StateC o  = (Ord o, Hashable o)
type SARMap o a r = HashMap o (HashMap a r)


data Configs r = Configs
  { gamma    :: r
  , epsilon  :: r
  , maxSteps :: Maybe Int
  , initialQ :: r
  }


defaultConfigs :: Configs Reward
defaultConfigs = Configs 0.99 0.1 (Just 2000) 0


data QTableState o a r = QTableState
  { qs     :: HashMap o (HashMap a r)
  , lambda :: Either r (Integer, r, Integer -> r -> r)
  }


qsL :: Lens' (QTableState o a r) (HashMap o (HashMap a r))
qsL = lens qs $ \(QTableState _ b) a -> QTableState a b

lambdaL :: Lens' (QTableState o a r) (Either r (Integer, r, Integer -> r -> r))
lambdaL = lens lambda $ \(QTableState a _) b -> QTableState a b

defaultQTableState :: (StateC o, Fractional r) => Either r (r, Integer -> r -> r) -> QTableState o a r
defaultQTableState (Left i)        = QTableState mempty (Left i)
defaultQTableState (Right (i, fn)) = QTableState mempty (Right (0, i, fn))


newtype QTable m o a r x = QTable
  { getQTable :: RWST (Configs r) [Event r o a] (QTableState o a r) m x }
  deriving
    ( Functor
    , Applicative
    , Monad
    , MonadIO
    , MonadReader (Configs r)
    , MonadWriter [Event r o a]
    , MonadState (QTableState o a r)
    , MonadRWS (Configs r) [Event r o a] (QTableState o a r)
    )


runQTable
  :: (MonadEnv m o a r, StateC o, Fractional r)
  => Configs r -> Either r (r, Integer -> r -> r) -> QTable m o a r x -> m (x, QTableState o a r, [Event r o a])
runQTable conf l (QTable e) = runRWST e conf (defaultQTableState l)


instance (MonadIO m, MonadMWCRandom m) => MonadMWCRandom (QTable m o a r) where
  getGen = liftIO getGen


instance MonadEnv m o a r => MonadEnv (QTable m o a r) o a r where
  step a = QTable $ lift (step a)
  reset  = QTable $ lift reset


instance (EnvC m, RewardC r, ActionC a, StateC o) => TDLearning (QTable m o a r) o a r where
  choose :: o -> QTable m o a r a
  choose obs = do
    Configs{epsilon, initialQ} <- ask
    QTableState{qs} <- get
    let acts = HM.toList $ HM.lookupDefault (initalTable initialQ) obs qs
    epsilonGreedy acts epsilon


  actions :: o -> QTable m o a r [a]
  actions obs = do
    Configs{initialQ} <- ask
    QTableState{qs} <- get
    let ars = HM.lookupDefault (initalTable initialQ) obs qs
    qsL %= HM.insert obs ars
    return $ HM.keys ars

  update :: o -> a -> r -> QTable m o a r ()
  update obs act updQ = qsL %= HM.update (Just . HM.insert act updQ) obs


  value :: o -> a -> QTable m o a r r
  value obs act = do
    Configs{initialQ} <- ask
    QTableState{qs}   <- get
    return $ fromMaybe initialQ (qs ^. at obs . _Just ^. at act)


initalTable :: (Enum a, Bounded a, Eq a, Hashable a, Enum r) => r -> HashMap a r
initalTable x = HM.fromList $ zip [minBound..maxBound] [x..]


instance Monad m => RLParams (QTable m o a r) r where
  getLambda :: QTable m o a r r
  getLambda = use lambdaL >>= \case
    Left l -> pure l
    Right (t, l, fn) ->
      lambdaL .= Right (t+1, l', fn)
      >> pure l'
      where
        l' = fn (t+1) l

  getGamma :: QTable m o a r r
  getGamma = gamma <$> ask
