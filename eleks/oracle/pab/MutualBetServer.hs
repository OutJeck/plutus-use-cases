{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE OverloadedStrings  #-}

module Main(main) where

import           Data.Aeson
import qualified Data.Aeson            as Aeson 
import qualified Data.Aeson.Extras     as Aeson          
import           Data.Text
import           Data.String           (fromString)
import           Control.Monad.Except
import           Control.Monad.Reader
import           GHC.Generics          (Generic)
import           Servant
import qualified Data.ByteString.Char8 as B
import           Ledger                (pubKeyHash, getPubKeyHash, PubKey, Address, PubKeyHash)
import           Network.Wai.Handler.Warp
import           Types.Game
import           Wallet.Emulator       (walletPubKeyHash, Wallet (..), knownWallet)
import qualified PlutusTx.Prelude      as PlutusTx

type GamesAPI = "wallet" :> Capture "id" Integer :> Get '[JSON] WalletData

data WalletData = WalletData
  { walletDataPubKeyHash    :: !PubKeyHash
  , walletId                :: !Text
  } deriving Generic
instance FromJSON WalletData
instance ToJSON WalletData

mutualBetAPI :: Proxy GamesAPI
mutualBetAPI = Proxy

mutualBetServer :: Server GamesAPI
mutualBetServer = wallet
  where 
    wallet:: Integer -> Handler WalletData
    wallet walletId = do

      let walletInst = knownWallet $ walletId
          pubKeyHash = walletPubKeyHash walletInst
      return WalletData { walletDataPubKeyHash   = pubKeyHash
                        , walletId               = toUrlPiece walletInst
                        }

mutualBetApp :: Application
mutualBetApp = serve mutualBetAPI mutualBetServer

main :: IO ()
main = do
  run 8082 mutualBetApp