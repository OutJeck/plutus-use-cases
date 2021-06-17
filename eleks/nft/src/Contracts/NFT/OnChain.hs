{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# options_ghc -fno-strictness         #-}
{-# options_ghc -fno-specialise         #-}

module Contracts.NFT.OnChain
    (marketInstance)
    where

import           Contracts.NFT.Types
import           Control.Monad                    hiding (fmap)
import qualified Data.Map                         as Map
import qualified Data.ByteString.Char8            as B
import qualified Data.ByteString.Base64           as B64
import qualified Data.Text                        as T
import           Data.Monoid                      (Last (..))
import           Data.Proxy                       (Proxy (..))
import           Data.Text                        (Text, pack)
import           Data.Void                        (Void)
import           Ledger                           hiding (singleton)
import qualified Ledger.Ada                       as Ada
import           Ledger.Constraints               as Constraints
import           Ledger.Constraints.OnChain       as Constraints
import           Ledger.Constraints.TxConstraints as Constraints
import qualified Ledger.Typed.Scripts             as Scripts
import           Ledger.Value                     (AssetClass (..), assetClass, assetClassValue, assetClassValueOf, valueOf,
                                                    symbols, unCurrencySymbol, unTokenName, CurrencySymbol (..))
import qualified Ledger.Value                     as Value
import qualified Ledger.Contexts                  as Validation
import           Playground.Contract
import           Plutus.Contract                  hiding (when)
import qualified Plutus.Contracts.Currency        as Currency
import qualified PlutusTx
import           PlutusTx.Prelude                 hiding (Semigroup (..), unless)
import           Prelude                          (Semigroup (..))
import qualified Prelude
import           Text.Printf                      (printf)
import           Wallet.Emulator                  (walletPubKey)

{-# INLINABLE findOwnInput' #-}
findOwnInput' :: ScriptContext -> TxInInfo
findOwnInput' ctx = fromMaybe (error ()) (findOwnInput ctx)

{-# INLINABLE valueWithin #-}
valueWithin :: TxInInfo -> Value
valueWithin = txOutValue . txInInfoResolved

{-# INLINABLE findMarketDatum #-}
findMarketDatum :: TxInfo -> DatumHash -> NFTMetadata
findMarketDatum info h = case findDatum h info of
    Just (Datum d) -> case PlutusTx.fromData d of
        Just (NFTMeta nft) -> nft
        _                -> traceError "error decoding data"
    _              -> traceError "market input datum not found"

{-# INLINABLE validateCreate #-}
validateCreate :: 
    NFTMarket
    -> [NFTMetadata]
    -> NFTMetadata
    -> ScriptContext
    -> Bool
validateCreate NFTMarket{..} nftMetas nftMeta@NFTMetadata{..} ctx =
    traceIfFalse "marketplace not present" (isMarketToken (valueWithin $ findOwnInput' ctx) marketId) &&
    traceIfFalse "nft token is arleady exists" (all (/= nftMeta) nftMetas) &&                                                                                 
    Constraints.checkOwnOutputConstraint ctx (OutputConstraint (Factory $ nftMeta : nftMetas) $ assetClassValue marketId 1) &&
    Constraints.checkOwnOutputConstraint ctx (OutputConstraint (NFTMeta nftMeta) $ getNftValue nftMetaTokenSymbol nftMetaTokenName)

{-# INLINABLE validateSell #-}
validateSell :: 
    NFTMarket
    -> NFTMetadata
    -> ScriptContext
    -> Bool
validateSell NFTMarket{..} nftMeta@NFTMetadata{nftMetaTokenSymbol, nftMetaTokenName, nftTokenSymbol, nftTokenName} ctx =
    traceIfFalse "owner should sign" ownerSigned                                                                    &&
    traceIfFalse "nft metadata token missing from input" (isNftToken inVal nftMetaTokenSymbol nftMetaTokenName)           &&
    traceIfFalse "ouptut nftMetadata should be same" (nftMeta == outDatum)                                          &&
    traceIfFalse "price should be greater than 0" (nftSellPrice outDatum > 0)                                    
  where
    info :: TxInfo
    info = scriptContextTxInfo ctx

    ownInput :: TxInInfo
    ownInput = findOwnInput' ctx

    ownOutput :: TxOut
    ownOutput = case [ o
                     | o <- getContinuingOutputs ctx
                     , isNftToken (txOutValue o) nftMetaTokenSymbol nftMetaTokenName &&
                       isNftToken (txOutValue o) nftTokenSymbol nftTokenName
                     ] of
        [o] -> o
        _   -> traceError "expected exactly one nft metadata output and one nft token output"

    outDatum :: NFTMetadata
    outDatum = case txOutDatum ownOutput of
        Nothing -> traceError "nft metadata not found"
        Just h  -> findMarketDatum info h

    inVal, outVal :: Value
    inVal  = valueWithin ownInput
    outVal = txOutValue ownOutput

    ownerSigned :: Bool
    ownerSigned = case nftSeller outDatum of
        Nothing      -> False
        Just pkh -> txSignedBy info pkh

{-# INLINABLE validateCancelSell #-}
validateCancelSell :: 
    NFTMarket
    -> NFTMetadata
    -> ScriptContext
    -> Bool
validateCancelSell NFTMarket{..} nftMeta@NFTMetadata{nftMetaTokenSymbol, nftMetaTokenName, nftTokenSymbol, nftTokenName} ctx =
    traceIfFalse "owner should sign" ownerSigned                                                            &&
    traceIfFalse "nft metadata token missing from input" (isNftToken inVal nftMetaTokenSymbol nftMetaTokenName)    &&
    traceIfFalse "nft token missing from input" (isNftToken inVal nftTokenSymbol nftTokenName)                   &&
    traceIfFalse "ouptut nftMetadata should be same" (nftMeta == outDatum)                                  &&
    traceIfFalse "price should be emptied" (nftSellPrice outDatum == 0)                                     &&
    traceIfFalse "seller should be emptied" (PlutusTx.Prelude.isNothing $ nftSeller outDatum)                                       
  where
    info :: TxInfo
    info = scriptContextTxInfo ctx

    ownInput :: TxInInfo
    ownInput = findOwnInput' ctx

    ownOutput :: TxOut
    ownOutput = case [ o
                     | o <- getContinuingOutputs ctx
                     , isNftToken (txOutValue o) nftMetaTokenSymbol nftMetaTokenName
                     ] of
        [o] -> o
        _   -> traceError "expected exactly one nft metadata output"

    outDatum :: NFTMetadata
    outDatum = case txOutDatum ownOutput of
        Nothing -> traceError "nft metadata not found"
        Just h  -> findMarketDatum info h

    inVal, outVal :: Value
    inVal  = valueWithin ownInput
    outVal = txOutValue ownOutput

    ownerSigned :: Bool
    ownerSigned = case nftSeller nftMeta of
        Nothing      -> False
        Just pkh     -> txSignedBy info pkh

{-# INLINABLE validateBuy #-}
validateBuy :: 
    NFTMarket
    -> NFTMetadata
    -> PubKeyHash
    -> ScriptContext
    -> Bool
validateBuy NFTMarket{..} nftMeta@NFTMetadata{nftMetaTokenSymbol, nftMetaTokenName, nftTokenSymbol, nftTokenName} buyer ctx =
    traceIfFalse "nft metadata token missing from input" $ isNftToken inVal nftMetaTokenSymbol nftMetaTokenName                  &&
    traceIfFalse "ouptut nftMetadata should be same" (nftMeta == outDatum)                                                     &&
    traceIfFalse "expected seller to get money" (addressGetValue (nftSeller nftMeta) $ Ada.lovelaceValueOf (nftSellPrice nftMeta))   &&   
    traceIfFalse "expected buyer to get NFT token" (addressGetValue (Just buyer) $ getNftValue nftTokenSymbol nftTokenName)        && 
    traceIfFalse "price should be grater 0" (nftSellPrice outDatum == 0)                                                       && 
    traceIfFalse "seller should be emptied" (PlutusTx.Prelude.isNothing $ nftSeller outDatum)
 where
    info :: TxInfo
    info = scriptContextTxInfo ctx

    ownInput :: TxInInfo
    ownInput = findOwnInput' ctx

    ownOutput :: TxOut
    ownOutput = case [ o
                     | o <- getContinuingOutputs ctx
                     , isNftToken (txOutValue o) nftMetaTokenSymbol nftMetaTokenName
                     ] of
        [o] -> o
        _   -> traceError "expected exactly one nft metadata output"

    outDatum :: NFTMetadata
    outDatum = case txOutDatum ownOutput of
        Nothing -> traceError "nft metadata not found"
        Just h  -> findMarketDatum info h

    inVal, outVal :: Value
    inVal  = valueWithin ownInput
    outVal = txOutValue ownOutput

    addressGetValue :: Maybe PubKeyHash -> Value -> Bool
    addressGetValue h v =
        let
        [o] = [ o'
              | o' <- txInfoOutputs info
              , txOutValue o' == v
              ]
        in
        fromMaybe False ((==) <$> Validation.pubKeyOutput o <*> h )

{-# INLINABLE mkNFTMarketValidator #-}
mkNFTMarketValidator :: 
    NFTMarket
    -> NFTMarketDatum
    -> NFTMarketAction
    -> ScriptContext
    -> Bool
mkNFTMarketValidator market (Factory nftMetas) (Create nftMeta) ctx = validateCreate market nftMetas nftMeta ctx
mkNFTMarketValidator market (NFTMeta nftMeta)  Sell             ctx = validateSell market nftMeta ctx
mkNFTMarketValidator market (NFTMeta nftMeta)  CancelSell       ctx = validateCancelSell market nftMeta ctx
mkNFTMarketValidator market (NFTMeta nftMeta)  (Buy buyer)      ctx = validateBuy market nftMeta buyer ctx
mkNFTMarketValidator _      _                  _                _   = False

-- {-# INLINABLE validateLiquidityForging #-}
-- validateNFTForging :: NFTMarket -> TxOutRef -> TokenName -> ScriptContext -> Bool
-- validateNFTForging Uniswap{..} tn ctx
--   = case [ i
--          | i <- txInfoInputs $ scriptContextTxInfo ctx
--          , let v = valueWithin i
--          , isUnity v usCoin || assetClassValueOf v marketId = 1
--          ] of
--     [_]    -> True
--     [_, _] -> True
--     _      -> traceError "pool state forging without Uniswap input"
--   where
--     lpC :: Coin Liquidity
--     lpC = mkCoin (ownCurrencySymbol ctx) tn

data Market
instance Scripts.ValidatorTypes Market where
    type instance RedeemerType Market = NFTMarketAction
    type instance DatumType Market = NFTMarketDatum

marketInstance :: NFTMarket -> Scripts.TypedValidator Market
marketInstance market = Scripts.mkTypedValidator @Market
    ($$(PlutusTx.compile [|| mkNFTMarketValidator ||])
        `PlutusTx.applyCode` PlutusTx.liftCode market)
     $$(PlutusTx.compile [|| wrap ||])
  where
    wrap = Scripts.wrapValidator @NFTMarketDatum @NFTMarketAction