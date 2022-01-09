//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Staking.sol";
import "hardhat/console.sol";

// compound once a day
contract Compound is Ownable {
    /* ========== STATE VARIABLES ========== */

    struct UserInfo {
        uint256 shares; // number of shares for a user
        uint256 stakeTime; // time of user deposit
        uint256 fee;
        uint256 excess;
    }

    uint256 public constant MINIMUM_STAKE = 1000 ether;
    uint256 public constant LOCK_PERIOD = 7 days;

    uint256 public totalStaked; // total amount of tokens staked
    uint256 public totalShares;
    uint256 public rewardRate; // token rewards per second
    uint256 public beginDate; // start date of rewards
    uint256 public endDate; // end date of rewards
    uint256 public lastUpdateTime;
    uint256 public feePerShare;
    uint256 public shareWorth;

    IERC20 public stakedToken; // token allowed to be staked

    mapping(address => uint256) public fees;
    mapping(address => UserInfo[]) public userInfo;

    /* ========== EVENTS ========== */

    event Deposit(
        address indexed sender,
        uint256 amount,
        uint256 shares,
        uint256 lastDepositedTime
    );

    event Withdraw(address indexed sender, uint256 amount, uint256 shares);
    event Harvest(address indexed sender);
    event Staked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event FeeDistributed(uint256 block, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 index);
    event RewardAdded(uint256 amount);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        IERC20 _stakedToken,
        uint256 _beginDate,
        uint256 _endDate
    ) {
        stakedToken = _stakedToken;
        lastUpdateTime = _beginDate;
        beginDate = _beginDate;
        endDate = _endDate;
        shareWorth = 1 ether;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function claim() external started updateShareWorth {
        uint256 reward;
        reward += calculateFees(msg.sender);
        reward += fees[msg.sender];
        if (reward > 0) {
            fees[msg.sender] = 0;
            stakedToken.transfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    function deposit(uint256 amount) external started updateShareWorth {
        require(amount >= MINIMUM_STAKE, "Stake too small");
        totalShares += (amount) / shareWorth;
        userInfo[msg.sender].push(
            UserInfo(
                amount / shareWorth,
                block.timestamp,
                feePerShare,
                amount - ((amount / shareWorth) * shareWorth)
            )
        );
        totalStaked -= ((amount / shareWorth) * shareWorth);
        stakedToken.transfer(msg.sender, amount);
        emit Deposit(
            msg.sender,
            amount,
            currentAmount(msg.sender),
            block.timestamp
        );
    }

    function withdrawAll() external updateShareWorth {
        uint256 _totalShares;
        uint256 _excess;

        for (uint256 i = 0; i < userInfo[msg.sender].length; i++) {
            if (
                userInfo[msg.sender][i].stakeTime + LOCK_PERIOD <=
                block.timestamp &&
                userInfo[msg.sender][i].shares > 0
            ) {
                uint256 _shares = userInfo[msg.sender][i].shares;
                _totalShares += _shares;
                _excess += userInfo[msg.sender][i].excess;
                userInfo[msg.sender][i].shares -= _shares;
                fees[msg.sender] = ((_shares *
                    (feePerShare - userInfo[msg.sender][i].fee)) / 1 ether);
            }
        }

        if (totalShares > 0) {
            totalShares -= _totalShares;
            totalStaked -= _totalShares * shareWorth;
            stakedToken.transfer(
                msg.sender,
                _totalShares * shareWorth + _excess
            );
            emit Withdraw(msg.sender, currentAmount(msg.sender), _totalShares);
        }
    }

    function withdraw(uint256 _shares, uint256 index)
        public
        started
        updateShareWorth
    {
        require(_shares > 0, "Cannot unstake 0");
        require(_shares <= userInfo[msg.sender][index].shares, "Stake too big");
        require(
            userInfo[msg.sender][index].stakeTime + LOCK_PERIOD <=
                block.timestamp,
            "Minimum lock period hasn't passed"
        );
        totalShares -= _shares;
        userInfo[msg.sender][index].shares -= _shares;
        fees[msg.sender] +=
            (_shares * (feePerShare - userInfo[msg.sender][index].fee)) /
            1 ether;
        totalStaked -= _shares * shareWorth;
        stakedToken.transfer(
            msg.sender,
            _shares * shareWorth + userInfo[msg.sender][index].excess
        );
        emit Withdraw(msg.sender, currentAmount(msg.sender), _shares);
    }

    function calculateFees(address user) internal returns (uint256) {
        uint256 _fees;
        for (uint256 i = 0; i < userInfo[user].length; i++) {
            _fees += ((userInfo[user][i].shares *
                (feePerShare - userInfo[user][i].fee)) / 1 ether);

            userInfo[user][i].fee = feePerShare;
        }
        return _fees;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function harvest() external updateShareWorth {
        emit Harvest(msg.sender);
    }

    function addReward(uint256 amount) external onlyOwner updateShareWorth {
        require(amount > 0, "Cannot add 0 reward");
        uint256 time = (endDate - firstTimeRewardApplicable());
        rewardRate += (amount) / time;
        stakedToken.transferFrom(
            msg.sender,
            address(this),
            (amount / time) * time
        );
        emit RewardAdded((amount / time) * time);
    }

    function feeDistribution(uint256 amount) external onlyOwner {
        require(amount > 0, "Cannot distribute 0 fee");
        require(totalStaked > 0, "Noone to distribute fee to");
        feePerShare += (amount * 1 ether) / (totalShares);
        uint256 result = (((amount * 1 ether) / (totalShares)) * totalShares) /
            1 ether;
        stakedToken.transferFrom(msg.sender, address(this), result);
        emit FeeDistributed(block.timestamp, result);
    }

    /* ========== VIEWS ========== */

    function currentAmount(address user) public view returns (uint256) {
        uint256 amount;
        for (uint256 i = 0; i < userInfo[user].length; i++) {
            amount += userInfo[user][i].shares;
        }
        return amount;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < endDate ? block.timestamp : endDate;
    }

    function firstTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < beginDate ? beginDate : block.timestamp;
    }

    /* ========== MODIFIERS ========== */

    modifier updateShareWorth() {
        if (totalStaked > 0) {
            for (
                uint256 i = 0;
                i < (lastTimeRewardApplicable() - lastUpdateTime) / 1 hours;
                i++
            ) {
                uint256 placeHolder = shareWorth;
                shareWorth += (shareWorth * 1 hours * rewardRate) / totalStaked;
                totalStaked += totalShares * (shareWorth - placeHolder);
            }
            lastUpdateTime = (lastTimeRewardApplicable() / 1 hours) * 1 hours;
        }
        _;
    }

    modifier started() {
        require(block.timestamp >= beginDate, "Stake period hasn't started");
        _;
    }
}
