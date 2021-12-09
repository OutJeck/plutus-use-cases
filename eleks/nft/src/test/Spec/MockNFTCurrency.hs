{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE MonoLocalBinds     #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE ViewPatterns       #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
-- | Implements a custom currency with a monetary policy that allows
--   the forging of a fixed amount of units.
module Spec.MockNFTCurrency(
    MockNFTCurrency(..)
    , testNftCurPolicy
    -- * Actions etc
    , forgeContract
    , forgedValue
    , currencySymbol
    , CurrencySchema
    , ForgeNftParams(..)
    , forgeNftToken
    ) where

import           Data.Text               (Text)
import           PlutusTx.Prelude        hiding (Monoid (..), Semigroup (..))
import           Plutus.Contract         as Contract
import           Ledger                  (CurrencySymbol, PubKeyHash, pubKeyHash,
                                          scriptCurrencySymbol, txId)
import qualified Ledger.Constraints               as Constraints
import           Ledger.Constraints.OnChain       as Constraints
import           Ledger.Constraints.TxConstraints as Constraints
import qualified Ledger.Contexts         as V
import           Ledger.Scripts
import           Ledger.Tx (getCardanoTxId)

import qualified PlutusTx                as PlutusTx

import qualified Ledger.Typed.Scripts    as Scripts
import           Ledger.Value            (TokenName, Value)
import qualified Ledger.Value            as Value

import           Data.Aeson              (FromJSON, ToJSON)
import           Data.Semigroup            (Last (..))
import           GHC.Generics            (Generic)
import           Prelude                 (String)
import qualified Prelude
import           Schema                  (ToSchema)

{-# ANN module ("HLint: ignore Use uncurry" :: String) #-}

data MockNFTCurrency = MockNFTCurrency
  { testCurTokenName :: TokenName
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (ToJSON, FromJSON)

PlutusTx.makeLift ''MockNFTCurrency

validate :: MockNFTCurrency -> () -> V.ScriptContext -> Bool
validate c@(MockNFTCurrency testTokenName) _ ctx@V.ScriptContext{V.scriptContextTxInfo=txinfo} =
    let
        -- see note [Obtaining the currency symbol]
        ownSymbol = V.ownCurrencySymbol ctx

        forged = V.txInfoMint txinfo
        expected = currencyValue ownSymbol c

        -- True if the pending transaction forges the amount of
        -- currency that we expect
        forgeOK =
          let v = forged == expected
          in traceIfFalse "Forged value should be as expected" v

        forgeNFT =
          let isNft = forged == Value.singleton ownSymbol testTokenName 1
          in traceIfFalse "Forged value should be 1" isNft
    in forgeOK && forgeNFT

testNftCurPolicy :: MockNFTCurrency -> MintingPolicy
testNftCurPolicy nftCur = mkMintingPolicyScript $
    $$(PlutusTx.compile [|| Scripts.wrapMintingPolicy . validate ||])
        `PlutusTx.applyCode`
            PlutusTx.liftCode nftCur

forgedValue :: MockNFTCurrency -> Value
forgedValue cur = currencyValue (currencySymbol cur) cur

currencyValue :: CurrencySymbol -> MockNFTCurrency -> Value
currencyValue curSymbol nftCur = Value.singleton curSymbol (testCurTokenName nftCur) 1

currencySymbol :: MockNFTCurrency -> CurrencySymbol
currencySymbol = scriptCurrencySymbol . testNftCurPolicy

forgeContract
    :: forall w s. PubKeyHash
    -> TokenName
    -> Contract w s Text MockNFTCurrency
forgeContract _ tokenName = do
    let theNftCurrency = MockNFTCurrency{ testCurTokenName = tokenName }
        curVali = testNftCurPolicy theNftCurrency
        lookups = Constraints.mintingPolicy curVali
    let forgeTx = Constraints.mustMintValue (forgedValue theNftCurrency)
    tx <- submitTxConstraintsWith @Scripts.Any lookups forgeTx
    _ <- awaitTxConfirmed $ getCardanoTxId tx
    pure theNftCurrency

-- | Miniting policy for a currency that has a fixed amount of tokens issued
--   in one transaction
data ForgeNftParams =
    ForgeNftParams
        { fnpTokenName :: TokenName
        }
        deriving stock (Prelude.Eq, Prelude.Show, Generic)
        deriving anyclass (FromJSON, ToJSON, ToSchema)

type CurrencySchema =
        Endpoint "create" ForgeNftParams

-- | Use 'forgeContract' to create the currency specified by a 'SimpleMPS'
forgeNftToken
    :: Promise (Maybe (Last MockNFTCurrency)) CurrencySchema Text ()
forgeNftToken = endpoint @"create" $ \ForgeNftParams{fnpTokenName} -> do
    ownPK <- ownPubKeyHash
    cur <- forgeContract ownPK fnpTokenName
    tell (Just (Last cur))
    