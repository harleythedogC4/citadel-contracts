// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {SafeMathUpgradeable} from "openzeppelin-contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {SafeERC20Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./interfaces/badger/IVault.sol";
import "./interfaces/erc20/IERC20.sol";
import "./lib/GlobalAccessControlManaged.sol";
import "./lib/SafeERC20.sol";

/**
 * @notice Sells a token at a predetermined price to whitelisted buyers.
 * TODO: Better revert strings
 */
contract Funding is GlobalAccessControlManaged, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20 for IERC20;

    // Roles used from GAC
    bytes32 public constant CONTRACT_GOVERNANCE_ROLE = keccak256("CONTRACT_GOVERNANCE_ROLE");
    bytes32 public constant POLICY_OPERATIONS_ROLE = keccak256("POLICY_OPERATIONS_ROLE");
    bytes32 public constant TREASURY_OPS_ROLE = keccak256("TREASURY_OPS_ROLE");
    bytes32 public constant TREASURY_VAULT_ROLE = keccak256("TREASURY_VAULT_ROLE");

    IERC20 public citadel; /// token to distribute (in vested xCitadel form)
    IVault public xCitadel; /// wrapped citadel form that is actually distributed
    IERC20 public asset; /// token to take in WBTC / bibbtc LP / CVX / bveCVX

    uint public citadelPriceInAsset; /// asset per citadel price eg. 1 WBTC (8 decimals) = 40,000 CTDL ==> price = 10^8 / 40,000
    uint public minCitadelPriceInAsset; /// Lower bound on expected citadel price in asset terms. Used as circuit breaker oracle.
    uint public maxCitadelPriceInAsset; /// Upper bound on expected citadel price in asset terms. Used as circuit breaker oracle.

    uint public xCitadelPriceInCitadel; /// xCitadel price per share

    // TODO: This will be calculated LIVE from cached ppfs
    uint public xCitadelPriceInAsset; /// citadel price modified by xCitadel pricePerShare

    address public citadelPriceInAssetOracle;
    address public saleRecipient;

    struct FundingParams {
        uint discount;
        uint minDiscount;
        uint maxDiscount;
        address discountManager;
        uint assetCumulativeFunded; /// persistent sum of asset amount in over lifetime of contract.
        uint assetCap; /// Max asset token that can be taken in by the contract (defines the cap for citadel sold)
    }
    
    FundingParams public funding;

    /// ==================
    /// ===== Events =====
    /// ==================

    // TODO: we should conform to some interface here
    event Deposit(
        address indexed buyer,
        uint256 assetIn,
        uint256 xCitadelOut,
        uint256 citadelValue
    );

    event CitadelPriceInAssetUpdated(uint256 citadelPrice);
    event xCitadelPriceInCitadelUpdated(uint256 xCitadelPrice);
    event SaleRecipientUpdated(address indexed recipient);
    event AssetCapUpdated(uint256 assetCap);

    event Sweep(address indexed token, uint256 amount);
    event ClaimToTreasury(address indexed token, uint256 amount);

    modifier onlyCitadelPriceInAssetOracle() {
        require(msg.sender == citadelPriceInAssetOracle, "onlyCitadelPriceInAssetOracle");
        _;
    }

    event DiscountLimitsSet(uint minDiscount, uint maxDiscount);
    event DiscountSet(uint discount);
    event DiscountManagerSet(address discountManager);

    /// =======================
    /// ===== Initializer =====
    /// =======================

    /**
     * @notice Initializer.
     * @param _gac Global access control
     * @param _citadel The token this contract will return in a trade
     * @param _asset The token this contract will receive in a trade
     * @param _xCitadel Staked citadel, citadel will be granted to funders in this form
     * @param _saleRecipient The address receiving the proceeds of the sale - will be citadel multisig
     * @param _assetCap The max asset that the contract can take
     */
    function initialize(
        address _gac,
        address _citadel,
        address _asset,
        address _xCitadel,
        address _saleRecipient,
        uint256 _assetCap
    ) external initializer {
        require(
            _saleRecipient != address(0),
            "TokenSale: sale recipient should not be zero"
        );

        __GlobalAccessControlManaged_init(_gac);
        __ReentrancyGuard_init();

        citadel = IERC20(_citadel);
        xCitadel = IVault(_xCitadel);
        asset = IERC20(_asset);
        saleRecipient = _saleRecipient;

        funding = FundingParams(
            0,
            0,
            0,
            address(0),
            0,
            _assetCap
        );
    }
    

    /// ==========================
    /// ===== Public actions =====
    /// ==========================

    /**
     * @notice Exchange `_assetAmountIn` of `asset` for `citadel`
     * @param _assetAmountIn Amount of `asset` to give
     * @param _minCitadelOut ID of DAO to vote for
     * @return citadelAmount_ Amount of `xCitadel` bought
     */
    function deposit(
        uint256 _assetAmountIn,
        uint256 _minCitadelOut
    ) external gacPausable returns (uint256 citadelAmount_) {
        require(_assetAmountIn > 0, "_assetAmountIn must not be 0");
        require(
            funding.assetCumulativeFunded.add(_assetAmountIn) <= funding.assetCap,
            "asset funding cap exceeded"
        );

        // Take in asset from user
        citadelAmount_ = getAmountOut(_assetAmountIn);
        require(citadelAmount_ >= _minCitadelOut, "minCitadelOut");
        asset.safeTransferFrom(msg.sender, saleRecipient, _assetAmountIn);

        // Deposit xCitadel and send to user
        // TODO: Check gas costs. How does this relate to market buying if you do want to deposit to xCTDL?
        uint xCitadelBeforeDeposit = xCitadel.balanceOf(address(this));
        xCitadel.depositFor(msg.sender, citadelAmount_);
        uint xCitadelAfterDeposit = xCitadel.balanceOf(address(this));
        uint xCitadelGained = xCitadelAfterDeposit - xCitadelBeforeDeposit;

        emit Deposit(msg.sender, _assetAmountIn, xCitadelGained, citadelAmount_);
    }

    /// =======================
    /// ===== Public view =====
    /// =======================

    /**
     * @notice Get the amount received when exchanging `asset`
     * @param _assetAmountIn Amount of `asset` to exchange
     * @return citadelAmount_ Amount of `citadel` received
     */
    function getAmountOut(uint256 _assetAmountIn)
        public
        view
        returns (uint256 citadelAmount_)
    {
        citadelAmount_ = (_assetAmountIn.mul(10**citadel.decimals())).div(
            citadelPriceInAsset
        );
    }

    /**
     * @notice Check how much `asset` can still be taken in, based on cap and cumulative amount funded
     * @return limitLeft_ Amount of `asset` that can still be exchanged for citadel
     */
    function getRemainingFundable() external view returns (uint256 limitLeft_) {
        uint assetCumulativeFunded = funding.assetCumulativeFunded;
        uint assetCap = funding.assetCap;
        if (assetCumulativeFunded < assetCap) {
            limitLeft_ = assetCap.sub(assetCumulativeFunded);
        }
    }

    function getFundingParams() external view returns (FundingParams memory) {
        return funding;
    }

    /**
     * @notice Set minimum and maximum discount
     * @dev managed by contract governance to place constraints around the parameter for policy operations to play within
     * @param _minDiscount minimum discount (in bps)
     * @param _maxDiscount maximum discount (in bps)
     */
    function setDiscountLimits(uint _minDiscount, uint _maxDiscount) external gacPausable onlyRole(CONTRACT_GOVERNANCE_ROLE) {
        funding.minDiscount = _minDiscount;
        funding.maxDiscount = _maxDiscount;

        emit DiscountLimitsSet(_minDiscount, _maxDiscount);
    }

    /**
     * @notice Set discount manually, within the constraints of min and max discount values
     * @dev managed by policy operations for rapid response to market conditions
     * @param _discount active discount (in bps)
     */
    function setDiscount(uint _discount) external gacPausable onlyRoleOrAddress(POLICY_OPERATIONS_ROLE, funding.discountManager) {
        require(_discount >= funding.minDiscount, "discount < minDiscount");
        require(_discount <= funding.maxDiscount, "discount > maxDiscount");

        funding.discount = _discount;
        
        emit DiscountSet(_discount);
    }

    /**
     * @notice Set a discount manager address
     * @dev This is intended to be used for an automated discount manager contract to supplement or replace manual calls
     * @param _discountManager discount manager address
     */
    function setDiscountManager(address _discountManager) external gacPausable onlyRole(CONTRACT_GOVERNANCE_ROLE) {
        funding.discountManager = _discountManager;

        emit DiscountManagerSet(_discountManager);
    }

    /// ==========================
    /// ===== Oracle actions =====
    /// ==========================

    /// @notice Update citadel price in asset terms from oracle source
    /// @dev Note that the oracle mechanics are abstracted to the oracle address
    function updateCitadelPriceInAsset(uint _citadelPriceInAsset) external gacPausable onlyCitadelPriceInAssetOracle {
        require(_citadelPriceInAsset > 0, "citadel price must not be zero");
        citadelPriceInAsset = _citadelPriceInAsset;

        emit CitadelPriceInAssetUpdated(_citadelPriceInAsset);
    }

    /// @notice Cache xCitadel value in citatdel terms by reading pricePerShare
    function updateXCitadelPriceInCitadel() external gacPausable onlyCitadelPriceInAssetOracle {
        xCitadelPriceInCitadel = xCitadel.getPricePerFullShare();
        emit xCitadelPriceInCitadelUpdated(xCitadelPriceInCitadel);
    }

    /**
     * @notice Update the `asset` receipient address. Can only be called by owner
     * @param _saleRecipient New recipient address
     */
    function setSaleRecipient(address _saleRecipient) external gacPausable onlyRole(CONTRACT_GOVERNANCE_ROLE) {
        require(
            _saleRecipient != address(0),
            "TokenSale: sale recipient should not be zero"
        );

        saleRecipient = _saleRecipient;
        emit SaleRecipientUpdated(_saleRecipient);
    }

    /**
     * @notice Modify the max asset amount that this contract can take. Managed by policy governance.
     * @dev This is cumulative asset cap, so must take into account the asset amount already funded.
     * @param _assetCap New max cumulatiive amountIn
     */
    function setAssetCap(uint256 _assetCap) external gacPausable onlyRole(POLICY_OPERATIONS_ROLE) {
        require(_assetCap > funding.assetCumulativeFunded, "cannot decrease cap below global sum of assets in");
        funding.assetCap = _assetCap;
        emit AssetCapUpdated(_assetCap);
    }

    /**
     * @notice Transfers out any tokens accidentally sent to the contract. Can only be called by owner
     * @dev The contract transfers all `asset` directly to `saleRecipient` during a sale so it's safe
     *      to sweep `asset`. For `citadel`, the function only sweeps the extra amount
     *      (current contract balance - amount left to be claimed)
     * @param _token The token to sweep
     */
    function sweep(address _token) external gacPausable onlyRole(TREASURY_OPS_ROLE) {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        require(amount > 0, "nothing to sweep");
        require(_token != address(asset), "cannot sweep funding asset, use claimAssetToTreasury()");

        IERC20(_token).safeTransfer(saleRecipient, amount);
        emit Sweep(_token, amount);
    }

    /// @notice Claim accumulated asset token to treasury
    /// @dev We let assets accumulate and batch transfer to treasury (rather than transfer atomically on each deposi)t for user gas savings
    function claimAssetToTreasury() external gacPausable onlyRole(TREASURY_OPS_ROLE) {
        uint256 amount = asset.balanceOf(address(this));
        require(amount > 0, "nothing to claim");
        asset.safeTransfer(saleRecipient, amount);

        emit ClaimToTreasury(address(asset), amount);
    }
}
