// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
* @title DSC Engine
* The system is disigned to be as minimal as possible.
* This stable coin has the proprieties:
* - Collateral: Exogenous (ETH, BTC)
* - Minting: Algoritmic
* - Relative Stability: Pegged to USD
* Our DSC System should always be "overcollateralized". At ne point, should the value of all collateral <= the $ backed value of all the DSC.
* 
* It is similar to DAI, but with a different minting algorithm.
* @notice This contract is the core of the DSC system. It handles all the logic for minting nd redeeming DSC.
* @notice This contract is very loosely based on the DAI stable coin.
*/

contract DSCEngine is ReentrancyGuard {
    /////////////////////
    //      Errors    //
    /////////////////////
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthustBeSame();
    error DSCEngine__TransferFailed();
    error DSCEngine__NotEnoughCollateral(uint256 healthFactor);
    error DSCEngine__MintFailed();
    /////////////////////////
    //  State Variables   //
    /////////////////////////

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_CollateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collaraltokens;

    uint256 private constant ADITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////////
    //      Events         //
    /////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedemded(address indexed user, address indexed token, uint256 indexed amount);

    modifier MoreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier NotAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory _tokenAddresses, address[] memory _priceFeeds, address _dscTokenAddress) {
        //USD Price Feed
        if (_tokenAddresses.length != _priceFeeds.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthustBeSame();
        }
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeeds[i];
            s_collaraltokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscTokenAddress);
    }

    /*
    * @param _tokenCollateralAddress The address of the token to be used as collateral
    * @param _amountCollateral The amount of collateral to be deposited
    * @param _amountDscToMint The amount of DSC to mint
    *   
    * @notice This function allows the user to deposit collateral and mint DSC
    */
    function depositAndMintDsc(address _tokenCollateralAddress, uint256 _amountCollateral, uint256 _amountDscToMint)
        external
    {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }
    /*
    * @param _tokenCollateralAddress The address of the token to be used as collateral
    * @param _amountCollateral The amount of collateral to be deposited
    * @notice This function allows the user to deposit collateral and mint DSC
    */

    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        MoreThanZero(_amountCollateral)
        NotAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    /*
    * @param _tokenCollateral The collateral address to redeem
    * @param _amountCollateral The amount of collateral to redeem
    * @param _amountDscToBurn The amount of DSC to burn
    */

    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
    }
    /*
    * This function allows the user to deposit collateral
    * @notice The health factor is checked before the user can deposit collateral
    */

    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        MoreThanZero(_amountCollateral)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedemded(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(msg.sender, _amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @param _amountDscToMint The amount of DSC to mint
    * @notice This function allows the user to mint DSC
    */

    function mintDsc(uint256 _amountDscToMint) public MoreThanZero(_amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
    *
    * @notice This function allows the user to burn DSC
    */
    function burnDsc(uint256 _amount) public MoreThanZero(_amount) {
        s_DscMinted[msg.sender] -= _amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate() external {}
    function getHeathFactor() external {}
    ////////////////////////////////////
    //  Private & Internal Functions  //
    ///////////////////////////////////

    function _getAcountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralInUsd)
    {
        totalDscMinted = s_DscMinted[_user];
        collateralInUsd = getAccountCollateralValue(_user);
        return (collateralInUsd, totalDscMinted);
    }

    /*
    * Returns how close to liquidate a user is
    * If a user go below 1, the user is liquidated
    * 
    * @param _user The address of the user
    */
    function _healthFactor(address _user) private view returns (uint256) {
        //Total dsc minted
        //total collateral value
        (uint256 totalCollateralValue, uint256 totalDscMinted) = _getAcountInformation(_user);
        uint256 collateralAdjustedForThreshold = (totalCollateralValue * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__NotEnoughCollateral(userHealthFactor);
        }
    }

    ////////////////////////////////////////////
    //   Public and External View Functions   //
    ////////////////////////////////////////////

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralUsd) {
        // loop through all the collateraltoken , get the amount they have deposited, and map it to
        // the price feed to get the value in USD
        for (uint256 i = 0; i < s_collaraltokens.length; i++) {
            address token = s_collaraltokens[i];
            uint256 amount = s_CollateralDeposited[_user][token];
            totalCollateralUsd += getUsdValue(token, amount);
        }
        return totalCollateralUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADITIONAL_FEED_PRECISION) * _amount) / PRECISION;
    }
}
