{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE NumericUnderscores         #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}

-- | A guessing game. A simplified version of 'Plutus.Contract.GameStateMachine'
-- using 'Cardano.Node.Emulator.MTL'.
module Plutus.Example.GameSpec (tests) where

import Cardano.Node.Emulator qualified as E
import Cardano.Node.Emulator.MTL (EmulatorM, MonadEmulator, getParams, logInfo, submitTxConfirmed, utxosAt)
import Cardano.Node.Emulator.MTL.Test (propRunActions_, propSanityCheckAssertions, propSanityCheckModel)
import Cardano.Node.Emulator.TimeSlot qualified as TimeSlot
import Control.Lens (makeLenses, (.=), (^.))
import Control.Monad (void, when)
import Control.Monad.Trans (lift)
import Data.Default (def)
import GHC.Generics (Generic)
import Ledger (CardanoAddress)
import Ledger qualified
import Ledger.CardanoWallet qualified as W
import Ledger.Tx.Constraints qualified as Constraints
import Ledger.Value.CardanoAPI qualified as Value
import Plutus.Example.Game (GameParam (GameParam), GuessArgs (GuessArgs, guessArgsGameParam, guessArgsSecret),
                            LockArgs (LockArgs, lockArgsGameParam, lockArgsSecret, lockArgsValue), mkGameAddress,
                            mkGuessTx, mkLockTx)
import Plutus.Script.Utils.Ada qualified as Ada
import PlutusTx.Prelude ()
import Test.QuickCheck qualified as QC
import Test.QuickCheck.ContractModel (Action, Actions, ContractModel, DL, RunModel, action, assertModel, forAllDL)
import Test.QuickCheck.ContractModel qualified as QCCM
import Test.QuickCheck.DynamicLogic (chooseQ, elementsQ, forAllQ)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty, withMaxSuccess)

w1 :: CardanoAddress
w1 = W.mockWalletAddress $ W.fromWalletNumber 1

gameParamTest :: GameParam
gameParamTest = GameParam (Ledger.toPlutusAddress w1) (TimeSlot.scSlotZeroTime def)

data GameModel = GameModel
    { _gameValue     :: Integer
    , _currentSecret :: String
    }
    deriving (Show, Generic)

makeLenses 'GameModel

type Wallet = Integer

instance ContractModel GameModel where

    -- The commands available to a test case
    data Action GameModel = Lock      Wallet String Integer
                          | Guess     Wallet String
        deriving (Eq, Show, Generic)

    initialState = GameModel
        { _gameValue     = 0
        , _currentSecret = ""
        }

    -- 'nextState' describes how each command affects the state of the model
    nextState (Lock w secret val) = do
        currentSecret .= secret
        gameValue     .= val
        QCCM.withdraw (E.knownAddresses !! (pred $ fromIntegral w)) $ Value.lovelaceValueOf val
        QCCM.wait 1

    nextState (Guess w guess) = do
        correct <- (guess ==) <$> QCCM.viewContractState currentSecret
        val <- QCCM.viewContractState gameValue
        when correct $ do
            gameValue     .= 0
            QCCM.deposit (E.knownAddresses !! (pred $ fromIntegral w)) $ Value.lovelaceValueOf val
        QCCM.wait 1

    -- To generate a random test case we need to know how to generate a random
    -- command given the current model state.
    arbitraryAction s = QC.oneof $
        genLockAction :
        [ pure (Guess w secret) | val > minOut, w <- wallets ]
        where
            minOut = Ada.getLovelace Ledger.minAdaTxOutEstimated
            val = s ^. QCCM.contractState . gameValue
            secret = s ^. QCCM.contractState . currentSecret
            genLockAction :: QC.Gen (Action GameModel)
            genLockAction = do
              w <- genWallet
              pure (Lock w) <*> genGuess <*> QC.choose (Ada.getLovelace Ledger.minAdaTxOutEstimated, Ada.getLovelace (Ada.adaOf 100))

    -- The 'precondition' says when a particular command is allowed.
    precondition s cmd = case cmd of
            -- In order to lock funds, we need to satifsy the constraint where
            -- each tx out must have at least N Ada.
            Lock _ _ v -> val == 0 && v >= Ada.getLovelace Ledger.minAdaTxOutEstimated
            Guess{}    -> True
        where
            val = s ^. QCCM.contractState . gameValue

    shrinkAction _s (Lock w secret val) =
        [Lock w' secret val | w' <- shrinkWallet w] ++
        [Lock w secret val' | val' <- QC.shrink val]
    shrinkAction _s (Guess w guess) =
        [Guess w' guess | w' <- shrinkWallet w]

instance RunModel GameModel EmulatorM where
    -- 'perform' gets a state, which includes the GameModel state, but also contract handles for the
    -- wallets and what the model thinks the current balances are.
    perform _ cmd _ = case cmd of
        Lock w secret val -> do
            lift $ submitLockTx (E.knownAddresses !! (pred $ fromIntegral w))
                LockArgs { lockArgsGameParam = gameParamTest
                         , lockArgsSecret = secret
                         , lockArgsValue = Ada.lovelaceValueOf val
                         }
        Guess w secret -> do
            lift $ submitGuessTx (E.knownAddresses !! (pred $ fromIntegral w))
                GuessArgs { guessArgsGameParam = gameParamTest
                          , guessArgsSecret = secret
                          }


prop_SanityCheckModel :: QC.Property
prop_SanityCheckModel = propSanityCheckModel @GameModel

prop_SanityCheckAssertions :: Actions GameModel -> QC.Property
prop_SanityCheckAssertions = propSanityCheckAssertions

wallets :: [Wallet]
wallets = [1, 2, 3]

genWallet :: QC.Gen Wallet
genWallet = QC.elements wallets

shrinkWallet :: Wallet -> [Wallet]
shrinkWallet w = filter (< w) wallets

genGuess :: QC.Gen String
genGuess = QC.elements ["hello", "secret", "hunter2", "*******"]

-- Dynamic Logic ----------------------------------------------------------

prop_UnitTest :: QC.Property
prop_UnitTest = QC.withMaxSuccess 1 $ forAllDL unitTest2 propRunActions_

unitTest1 :: DL GameModel ()
unitTest1 = do
    val <- forAllQ $ chooseQ (5_000_000, 20_000_000)
    action $ Lock 1 "hello" val
    action $ Guess 2 "hello"

unitTest2 :: DL GameModel ()
unitTest2 = do
    unitTest1
    action $ Guess 2 "new secret"

noLockedFunds :: DL GameModel ()
noLockedFunds = do
    QCCM.anyActions_
    w      <- forAllQ $ elementsQ wallets
    secret <- QCCM.viewContractState currentSecret
    val    <- QCCM.viewContractState gameValue
    when (val >= Ada.getLovelace Ledger.minAdaTxOutEstimated) $ do
        QCCM.monitor $ QC.label "Unlocking funds"
        action $ Guess w secret
    assertModel "Locked funds should be zero" $ QCCM.symIsZero . QCCM.lockedValue

-- | Check that we can always get the money out of the guessing game (by guessing correctly).
prop_NoLockedFunds :: QC.Property
prop_NoLockedFunds = forAllDL noLockedFunds propRunActions_

submitLockTx :: MonadEmulator m => CardanoAddress -> LockArgs -> m ()
submitLockTx wallet lockArgs@LockArgs { lockArgsValue } = do
    logInfo @String $ "Pay " <> show lockArgsValue <> " to the script"
    params <- getParams
    -- TODO How to throw custom errors?
    (Constraints.UnbalancedCardanoTx utx utxoIndex) <- either (error . show) pure $ mkLockTx params lockArgs
    let privateKey = lookup wallet $ zip E.knownAddresses E.knownPaymentPrivateKeys
    void $ submitTxConfirmed utxoIndex wallet privateKey utx

submitGuessTx :: MonadEmulator m => CardanoAddress -> GuessArgs -> m ()
submitGuessTx wallet guessArgs@GuessArgs { guessArgsGameParam } = do
    logInfo @String "Waiting for script to have a UTxO of at least 1 lovelace"
    utxos <- utxosAt (mkGameAddress guessArgsGameParam)
    params <- getParams
    -- TODO How to throw custom errors?
    (Constraints.UnbalancedCardanoTx utx utxoIndex) <- either (error . show) pure $ mkGuessTx params utxos guessArgs
    let privateKey = lookup wallet $ zip E.knownAddresses E.knownPaymentPrivateKeys
    void $ submitTxConfirmed utxoIndex wallet privateKey utx

tests :: TestTree
tests =
    testGroup "game (MTL) tests"
        [ testProperty "can always get the funds out" $
            withMaxSuccess 10 prop_NoLockedFunds
        , testProperty "sanity check the contract model" prop_SanityCheckModel
        , testProperty "sanity check assertions" prop_SanityCheckAssertions
        , testProperty "unit test" prop_UnitTest
        ]
