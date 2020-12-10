// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "./utils/SafeMath.sol";
import "./utils/Ownable.sol";
import "./interfaces/IClaimConfig.sol";
import "./interfaces/ICoverPool.sol";

/**
 * @title Config for ClaimManagement contract
 * @author Alan
 */
contract ClaimConfig is IClaimConfig, Ownable {
    using SafeMath for uint256;
    
    bool public override allowPartialClaim = true;

    address public override auditor;
    address public override governance;
    address public override treasury;
    address public override coverPoolFactory;
    
    // The max time allowed from filing a claim to a decision made
    uint256 public override maxClaimDecisionWindow = 7 days;
    uint256 public override baseClaimFee = 10e18;
    uint256 public override forceClaimFee = 500e18;
    uint256 public override feeMultiplier = 2;

    // coverPool => claim fee
    mapping(address => uint256) private coverPoolClaimFee;

    IERC20 public override feeCurrency = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    modifier onlyGov() {
        require(msg.sender == governance, "COVER_CC: !governance");
        _;
    }

    /**
     * @notice Set the address of governance
     * @dev Governance address cannot be set to owner or 0 address
     */
    function setGovernance(address _governance) external override onlyGov {
        require(_governance != address(0), "COVER_CC: governance cannot be 0");
        require(_governance != owner(), "COVER_CC: governance cannot be owner");
        governance = _governance;
    }

    /**
     * @notice Set the address of treasury
     */
    function setTreasury(address _treasury) external override onlyOwner {
        require(_treasury != address(0), "COVER_CC: treasury cannot be 0");
        treasury = _treasury;
    }

    /**
     * @notice Set max time window allowed to decide a claim after filed, requires at least 3 days for voting
     */
    function setMaxClaimDecisionWindow(uint256 _newTimeWindow) external override onlyOwner {
        require(_newTimeWindow < 3 days, "COVER_CC: window too short");
        maxClaimDecisionWindow = _newTimeWindow;
    }

    /**
     * @notice Set the status and address of auditor
     */
    function setAuditor(address _auditor) external override onlyOwner {
        auditor = _auditor;
    }

    /**
     * @notice Set the status of allowing partial claims
     */
    function setPartialClaimStatus(bool _allowPartialClaim) external override onlyOwner {
        allowPartialClaim = _allowPartialClaim;
    }

    /**
     * @notice Set fees and currency of filing a claim
     * @dev `_forceClaimFee` must be > `_baseClaimFee`
     */
    function setFeeAndCurrency(uint256 _baseClaimFee, uint256 _forceClaimFee, address _currency)
        external 
        override 
        onlyGov 
    {
        require(_baseClaimFee > 0, "COVER_CC: baseClaimFee <= 0");
        require(_forceClaimFee > _baseClaimFee, "COVER_CC: forceClaimFee <= baseClaimFee");
        require(_currency != address(0), "COVER_CC: feeCurrency cannot be 0");
        baseClaimFee = _baseClaimFee;
        forceClaimFee = _forceClaimFee;
        feeCurrency = IERC20(_currency);
    }

    /**
     * @notice Set the fee multiplier to `_multiplier`
     * @dev `_multiplier` must be atleast 1
     */
    function setFeeMultiplier(uint256 _multiplier) external override onlyGov {
        require(_multiplier >= 1, "COVER_CC: multiplier < 1");
        feeMultiplier = _multiplier;
    }

    /**
     * @notice Get status of auditor voting
     * @dev Returns false if `auditor` is 0
     * @return status of auditor voting in decideClaim
     */
    function isAuditorVoting() public view override returns (bool) {
        return auditor != address(0);
    }

    /**
     * @notice Get the claim fee for coverPool `_coverPool`
     * @dev Will return `baseClaimFee` if fee is 0
     * @return fee for filing a claim for coverPool
     */
    function getCoverPoolClaimFee(address _coverPool) public view override returns (uint256) {
        return coverPoolClaimFee[_coverPool] == 0 ? baseClaimFee : coverPoolClaimFee[_coverPool];
    }

    /**
     * @notice Get the time window allowed to file after an incident happened
     * @dev it is calculated based on the noclaimRedeemDelay of the coverPool - (maxClaimDecisionWindow) - 1hour
     * @return time window
     */
    function getFileClaimWindow(address _coverPool) public view override returns (uint256) {
        uint256 noclaimRedeemDelay = ICoverPool(_coverPool).noclaimRedeemDelay();
        return noclaimRedeemDelay.sub(maxClaimDecisionWindow).sub(1 hours);
    }

    /**
     * @notice Updates fee for coverPool `_coverPool` by multiplying current fee by `feeMultiplier`
     * @dev coverPoolClaimFee[coverPool] cannot exceed `baseClaimFee`
     */
    function _updateCoverPoolClaimFee(address _coverPool) internal {
        uint256 newFee = getCoverPoolClaimFee(_coverPool).mul(feeMultiplier);
        if (newFee <= forceClaimFee) {
            coverPoolClaimFee[_coverPool] = newFee;
        }
    }

    /**
     * @notice Resets fee for coverPool `_coverPool` to `baseClaimFee`
     */
    function _resetCoverPoolClaimFee(address _coverPool) internal {
        coverPoolClaimFee[_coverPool] = baseClaimFee;
    }
}