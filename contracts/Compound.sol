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
        uint256 sharePrice;
        uint256 shares; // number of shares for a user
        uint256 stakeTime; // time of user deposit
        uint256 fee;
        uint256 excess;
    }

    uint256 public shareWorth;
    uint256 public lastUpdateTime;
    uint256 public shares;
    IERC20 public stakedToken;
    Staking public staking;

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

    /* ========== CONSTRUCTOR ========== */

    constructor(IERC20 _stakedToken, address _staking) {
        stakedToken = _stakedToken;
        staking = Staking(_staking);
        lastUpdateTime = staking.beginDate();

        shareWorth = 1 ether;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint256 amount) external started updateShareWorth {
        require(amount >= staking.MINIMUM_STAKE(), "Stake too small");
        shares += (amount) / shareWorth;
        userInfo[msg.sender].push(
            UserInfo(
                shareWorth,
                amount / shareWorth,
                block.timestamp,
                staking.feePerToken(),
                amount - ((amount / shareWorth) * shareWorth)
            )
        );

        staking.autoCompStake(((amount / shareWorth) * shareWorth));
        stakedToken.transferFrom(msg.sender, address(staking), amount);

        emit Deposit(
            msg.sender,
            amount,
            currentAmount(msg.sender),
            block.timestamp
        );
    }

    function withdrawAll() external updateShareWorth {
        uint256 totalShares;
        uint256 _excess;

        for (uint256 i = 0; i < userInfo[msg.sender].length; i++) {
            if (
                userInfo[msg.sender][i].stakeTime + staking.LOCK_PERIOD() <=
                block.timestamp &&
                userInfo[msg.sender][i].shares > 0
            ) {
                uint256 _shares = userInfo[msg.sender][i].shares;
                totalShares += _shares;
                _excess += userInfo[msg.sender][i].excess;

                userInfo[msg.sender][i].shares -= _shares;

                staking.addFee(
                    msg.sender,
                    (_shares *
                        userInfo[msg.sender][i].sharePrice *
                        (staking.feePerToken() - userInfo[msg.sender][i].fee)) /
                        1 ether
                );
            }
        }

        console.log(totalShares * shareWorth + _excess);
        console.log(stakedToken.balanceOf(address(staking)));

        if (totalShares > 0) {
            shares -= totalShares;
            staking.autoCompUnstake(totalShares * shareWorth);
            staking.transferReward(
                totalShares * shareWorth + _excess,
                msg.sender
            );
            emit Withdraw(msg.sender, currentAmount(msg.sender), totalShares);
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
            userInfo[msg.sender][index].stakeTime + staking.LOCK_PERIOD() <=
                block.timestamp,
            "Minimum lock period hasn't passed"
        );
        shares -= _shares;
        userInfo[msg.sender][index].shares -= _shares;

        staking.addFee(
            msg.sender,
            (_shares *
                userInfo[msg.sender][index].sharePrice *
                (staking.feePerToken() - userInfo[msg.sender][index].fee)) /
                1 ether
        );

        staking.autoCompUnstake(_shares * shareWorth);
        staking.transferReward(
            _shares * shareWorth + userInfo[msg.sender][index].excess,
            msg.sender
        );

        emit Withdraw(msg.sender, currentAmount(msg.sender), _shares);
    }

    function calculateFees(address user) external {
        for (uint256 i = 0; i < userInfo[user].length; i++) {
            staking.addFee(
                user,
                ((userInfo[user][i].shares * userInfo[user][i].sharePrice) *
                    (staking.feePerToken() - userInfo[user][i].fee)) / 1 ether
            );
            userInfo[user][i].fee = staking.feePerToken();
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    function harvest() external updateShareWorth {
        emit Harvest(msg.sender);
    }

    /* ========== VIEWS ========== */

    function currentAmount(address user) public view returns (uint256) {
        uint256 amount;
        for (uint256 i = 0; i < userInfo[user].length; i++) {
            amount += userInfo[msg.sender][i].shares;
        }
        return amount;
    }

    /* ========== MODIFIERS ========== */

    modifier updateShareWorth() {
        if (staking.totalStaked() > 0) {
            for (
                uint256 i = 0;
                i <
                (staking.lastTimeRewardApplicable() - lastUpdateTime) / 1 hours;
                i++
            ) {
                uint256 placeHolder = shareWorth;
                shareWorth +=
                    (shareWorth * 1 hours * staking.rewardRate()) /
                    staking.totalStaked();

                staking.autoCompStake(shares * (shareWorth - placeHolder));
            }
            lastUpdateTime =
                (staking.lastTimeRewardApplicable() / 1 hours) *
                1 hours;
        }
        _;
    }

    modifier started() {
        require(
            block.timestamp >= staking.beginDate(),
            "Stake period hasn't started"
        );
        _;
    }
}
