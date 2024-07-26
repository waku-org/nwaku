In this tutorial you will learn how to:
1. Create a Sepolia Ethereum account and obtain its private key.
2. Obtain Sepolia ETH from faucet.
3. Access a node on the Sepolia testnet using Infura.

## 1. Create a Sepolia Ethereum account and obtain its private key

> _**WARNING:**_ The private key is used elsewhere by Waku RLN registration tools to assist with membership registration in the Sepolia test network.
> We strongly recommend that you create an account only for this purpose.
> NEVER expose a private key that controls any valuable assets or funds.

1. Download and install Metamask. [https://metamask.io/download/](https://metamask.io/download/)
   If you already have Metamask installed, go to step 3.
   If you encounter any issues during the Metamask setup process, please refer to the [official Metamask support page](https://support.metamask.io/hc/en-us). 
2. Create a new wallet and save your secret recovery phrase.
    
    ![](https://i.imgur.com/HEOI0kp.jpg)

3. Login to Metamask.
    
    ![](https://i.imgur.com/zFduIV8.jpg)

4. By default, Metamask connects to the Ethereum Mainnet (dropdown menu in the top right corner).
    
    ![](https://i.imgur.com/gk3TWUd.jpg)

   To publish messages to the Waku Network, you need to connect to the Sepolia test network.
5. Switch to the Sepolia test network by selecting it from the dropdown menu. Ensure "Show test networks" is enabled.

    ![image](https://github.com/waku-org/nwaku/assets/68783915/670778eb-8bf0-42a6-8dd7-1dedfabeeb37)

   The same account can be used with different networks. Note that the ETH balance is different for each network (each has its own native token).
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/0a5aa3a7-359c-4f4b-bd12-bad7c4844b34)

6. To view the private key for this account, click on the three dots next to the account name and select "Account Details".
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/83fffa23-4a3b-46f9-a492-9748bfd47cff)

   Select "Show Private Key".
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/3a513389-2df1-4e32-86da-a1794126cdac)

   Enter your Metamask password and click "Confirm"
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/ffbac631-b933-4292-a2c6-dc445bff153c)

   You will be shown the private key.

## 2. Obtain Sepolia ETH from faucet

Sepolia ETH can be obtained from different faucets.
Three popular examples include:

  1. [sepoliafaucet.com](https://sepoliafaucet.com/) (requires an Alchemy account)
  2. [Infura Sepolia faucet](https://www.infura.io/faucet/sepolia) (requires an Infura account)
  3. [Sepolia POW faucet](https://sepolia-faucet.pk910.de/)

> _**NOTE:**_ This list is provided for convenience. We do not necessarily recommend or guarantee the security of any of these options.

Many faucets limit the amount of Sepolia ETH you can obtain per day.
We include instructions for [sepolia-faucet.pk910.de](https://sepolia-faucet.pk910.de/) as an example:

1. Enter your Sepolia Ethereum account public address, solve the Captcha and start mining.
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/8bf2eece-956c-4449-ac4c-a7b9f4641c99)

2. Keep the browser tab open for a while. You can see the estimated Sepolia ETH mined per hour. 
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/fac1c6cb-b72f-47b1-a358-4ce41224a688)

   Each session is limited to a few hours. 
3. When you've mined enough Sepolia ETH (minimum of 0.05 Sepolia ETH), click on "Stop Mining" and claim your reward.
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/9ace2824-9030-4507-9b5f-50354bb99127)    
    
## 3. Access a node on the Sepolia testnet using Infura

> _**NOTE:**_ Infura provides a simple way of setting up endpoints for interaction with the Ethereum chain and the Waku RLN smart contract without having to run a dedicated Ethereum node.
> Setting up Infura is not mandatory. Operators concerned with the centralized aspect introduced by Infura should use their own node.

1. Sign up for Infura if you do not have an account already. [https://infura.io/register](https://infura.io/register)
    
    ![](https://i.imgur.com/SyLaG6s.jpg)

   Follow the instructions to register and verify the account.

2. Click on "Create a new API key".

    ![image](https://github.com/waku-org/nwaku/assets/68783915/3cf1d537-9f73-4a6a-b1ef-bbac148bac47)

4. Select "Web 3 API", give your API key a descriptive name and click on "Create".

    ![image](https://github.com/waku-org/nwaku/assets/68783915/f8c6c6b0-e55e-4681-8524-08303db11b9f)

   You will be presented with a dashboard for the newly created key.
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/54c7c2da-f512-4c48-b5bb-ff86cae021c6)

4. Select "Sepolia" in the dropdown menu for Ethereum.
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/945bf11e-15f6-48a9-9378-f7d39f73b02c)

   Both Https and WebSockets endpoints are available. Waku requires the Https endpoint.
    
    ![image](https://github.com/waku-org/nwaku/assets/68783915/adb2bac0-8f86-47d0-92cc-33d23f02aeb3)

5. Copy this address (starting with `https://sepolia.infura`) as needed when setting up your Waku node.
