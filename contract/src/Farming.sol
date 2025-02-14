// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FarmingJUN is Ownable {
    using SafeERC20 for IERC20;

    struct UserInfo {
        // 用户提供的 LP 代币数量
        uint256 amount;
        // 用户应得的奖励
        uint256 rewardDebt;
    }

    struct PoolInfo {
        // 质押的代币
        IERC20 lpToken;
        // 权重
        uint256 allocPoint;
        // 最后一次分发奖励的时间戳
        uint256 lastRewardTimestamp;
        // 每股累计奖励
        uint256 accJunPerShare;
        // 当前池子的总质押量
        uint256 totalDeposits;
    }

    // 代币合约地址
    IERC20 public erc20;

    // 已经支付的代币奖励
    uint256 public paidReward;

    // 每秒发放的 代币奖励数量
    uint256 public rewardPerSecond;

    // 总奖励数量
    uint256 public totalReward;

    // 所有矿池信息
    PoolInfo[] public pools;

    // Info of each user that stakes LP tokens.
    // 质押 LP 代币的用户信息映射
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // 总分配点数,必须等于所有矿池的分配点数之和
    uint256 public totalAllocPoint;

    // 挖矿开始时间戳
    uint256 public startTimestamp;

    // 挖矿结束时间戳
    uint256 public endTimestamp;

    event AddPool(uint256 indexed totalAllocPoint, uint256 poolLength);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        IERC20 _erc20,
        uint256 _rewardPerSecond,
        uint256 _startTimestamp
    ) Ownable(msg.sender) {
        erc20 = _erc20;
        rewardPerSecond = _rewardPerSecond;
        startTimestamp = _startTimestamp;
        endTimestamp = _startTimestamp;
    }

    // 注资
    function fund(uint256 _amount) public {
        require(block.timestamp < endTimestamp, "Farming is over");
        require(_amount > 0, "Amount must be greater than 0");
        erc20.safeTransferFrom(msg.sender, address(this), _amount);
        endTimestamp += _amount / rewardPerSecond;
        totalReward += _amount;
    }

    // 添加LP代币以及矿池
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardTimestamp = block.timestamp > startTimestamp
            ? block.timestamp
            : startTimestamp;
        totalAllocPoint += _allocPoint;
        pools.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: lastRewardTimestamp,
                accJunPerShare: 0,
                totalDeposits: 0
            })
        );

        emit AddPool(totalAllocPoint, pools.length - 1);
    }

    // 调整矿池权重
    function set(
        uint256 _pid,
        uint256 _newAllocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint =
            totalAllocPoint -
            pools[_pid].allocPoint +
            _newAllocPoint;
        pools[_pid].allocPoint = _newAllocPoint;
    }

    // 获取矿池数量
    function poolLength() public view returns (uint256) {
        return pools.length;
    }

    // 查看用户在指定矿池中质押的 LP 代币数量
    function deposited(
        uint256 _pid,
        address _user
    ) public view returns (uint256) {
        return userInfo[_pid][_user].amount;
    }

    // 查看用户在指定矿池中应得的奖励
    function pendingReward(
        uint256 _pid,
        address _user
    ) public view returns (uint256) {
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        // 每股累计奖励
        uint256 accJunPerShare = pool.accJunPerShare;
        // 当前池子的总质押量
        uint256 lpSupply = pool.totalDeposits;
        //  只有在当前时间超过上次结算时间且池子有质押时才需要更新
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            // 计算从上次分发奖励到当前时间的奖励
            uint256 lastRewardTimestamp = block.timestamp > endTimestamp
                ? block.timestamp
                : endTimestamp;
            uint256 timeStampToCompare = pool.lastRewardTimestamp < endTimestamp
                ? pool.lastRewardTimestamp
                : endTimestamp;
            uint256 timeDiff = lastRewardTimestamp - timeStampToCompare;
            // 计算这段时间内的总奖励
            uint256 reward = (timeDiff * rewardPerSecond * pool.allocPoint) /
                totalAllocPoint;
            // 更新每股累计奖励
            accJunPerShare = accJunPerShare + (reward * 1e18) / lpSupply;
        }
        // 计算用户应得奖励 = 用户质押量 * 每股累计奖励 - 已领取的奖励
        return (user.amount * accJunPerShare) / 1e18 - user.rewardDebt;
    }

    // 更新所有矿池
    function massUpdatePools() public {
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // 更新指定矿池
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = pools[_pid];
        // 如果当前时间超过结束时间，则结束时间等于当前时间
        uint256 lastTimestamp = block.timestamp < endTimestamp
            ? block.timestamp
            : endTimestamp;

        if (lastTimestamp <= pool.lastRewardTimestamp) {
            return;
        }

        uint256 lpSupply = pool.totalDeposits;

        if (lpSupply == 0) {
            pool.lastRewardTimestamp = lastTimestamp;
            return;
        }

        uint256 timeDiff = lastTimestamp - pool.lastRewardTimestamp;
        uint256 reward = (timeDiff * rewardPerSecond * pool.allocPoint) / totalAllocPoint;

        pool.accJunPerShare = pool.accJunPerShare + (reward * 1e18) / lpSupply;
        pool.lastRewardTimestamp = lastTimestamp;
    }

    // Transfer ERC20 and update the required ERC20 to payout all rewards
    // 转账 ERC20 代币并更新已支付奖励总量
    // _to: 接收地址
    // _amount: 转账金额
    function erc20Transfer(address _to, uint256 _amount) internal {
        erc20.transfer(_to, _amount);
        paidReward += _amount;
    }


    // 质押
    function deposit(uint256 _pid, uint256 _amount) public {
        require(block.timestamp < endTimestamp, "Farming is over");
        require(_amount > 0, "Amount must be greater than 0");
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        // 更新 矿池
        updatePool(_pid);
        // 如果用户已有质押,先结算之前的奖励
        if(user.amount > 0) {
            uint256 pendingAmount = user.amount * pool.accJunPerShare / 1e18 - user.rewardDebt;
            erc20Transfer(msg.sender, pendingAmount);
        }

        // 转入质押 LP 代币
        pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
        // 更新矿池质押量
        pool.totalDeposits = pool.totalDeposits + _amount;
        // 更新用户质押量
        user.amount = user.amount + _amount;
        // 更新用户应得奖励
        user.rewardDebt = user.amount * pool.accJunPerShare / 1e18;
        // 触发质押事件
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from Farm.
    // 提取 LP 代币
    // _pid: 矿池ID
    // _amount: 提取数量
    // 包含两个功能:
    // 1. 收取当前所有未领取的奖励
    // 2. 提取指定数量的质押代币
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "Withdraw amount must be less than or equal to the user's deposit");
        // 更新 矿池奖励状态
        updatePool(_pid);
        // 计算并发放所有未领取的奖励
        uint256 pendingAmount = user.amount * pool.accJunPerShare / 1e18 - user.rewardDebt;
        // 发放奖励
        erc20Transfer(msg.sender, pendingAmount);
        // 更新用户质押量
        user.amount = user.amount - _amount;
        // 更新用户应得奖励
        user.rewardDebt = user.amount * pool.accJunPerShare / 1e18;
        // 提取质押代币
        pool.lpToken.safeTransfer(msg.sender, _amount);
        // 更新矿池质押量
        pool.totalDeposits = pool.totalDeposits - _amount;

        // 触发提取事件
        emit Withdraw(msg.sender, _pid, _amount);
            
    }

    // 紧急提取功能: 不计算奖励,直接提取所有质押的 LP 代币
    // 用于紧急情况下快速退出,会损失所有未领取的奖励
    // _pid: 矿池ID
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        // 提取所有质押的 LP 代币
        pool.lpToken.safeTransfer(msg.sender, user.amount);
        // 更新矿池质押量
        pool.totalDeposits = pool.totalDeposits - user.amount;
        // 更新用户质押量
        user.amount = 0;
        user.rewardDebt = 0;
        // 触发紧急提取事件
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);  
    }



}
