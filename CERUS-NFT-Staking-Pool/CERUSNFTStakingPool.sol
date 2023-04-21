/**
 * @title CERUS NFT Staking Pool
 * @dev Allows users to deposit CERUS NFTs and earn rewards in METIS and CERUS tokens.
 * Rewards are distributed according to the user's share of the total staked NFTs.
 * The reward distribution rate is set by the owner and can be updated at any time.
 * Rewards can be claimed at any time by users, and users can also withdraw their staked NFTs.
 * The contract supports batch deposit and withdrawal of NFTs.
 * The contract only allows ERC721Enumerable NFTs!
 *
 * Owner can:
 * - initialize contract with collection and reward tokens addresses.
 * - sync reward: set a new reward period and sync emissions.
 * @dev the last reward period must have ended before syncing reward!
 *
 * Users can:
 * - deposit and withdraw nft tokens.
 * - claim reward.
 */

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CERUSNFTStakingPool is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    // Events.
    event Deposit(address indexed user, uint256 tokenId);
    event Withdraw(address indexed user, uint256 tokenId);
    event EmergencyWithdraw(address indexed user, uint256[] tokenIds);
    event SyncedReward(uint256 amountPrimary, uint256 amountSecondary, uint256 timeInSeconds);
    event Claim(address indexed user, uint256 amountPrimary, uint256 amountSecondary);

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebtPrimary; // Reward debt. See explanation below.
        uint256 rewardDebtSecondary; // Reward debt. See explanation below.
        uint256[] tokenIds; // user tokens by id.
    }

    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;

    // Info pool.
    struct PoolInfo {
        IERC721Enumerable collection; // Address of LP token contract.
        uint256 lastRewardTime; // Last block number that reward distribution occurs.
        uint256 accRewardPerSharePrimary; // Accumulated reward per share, times PRECISION. See below.
        uint256 accRewardPerShareSecondary; // Accumulated reward per share, times PRECISION. See below.
    }

    // Info of pool.
    PoolInfo public poolInfo;

    // Info of Reward.
    struct Reward {
        uint256 amountPrimary;
        uint256 amountSecondary;
    }
    Reward[] rewards;

    // The reward tokens.
    IERC20 public rewardTokenPrimary;
    IERC20 public rewardTokenSecondary;

    //  Tokens rewarded per block aka emission.
    uint256 public rewardPerSecondPrimary;
    uint256 public rewardPerSecondSecondary;

    // Precision factor used for calculations.
    uint256 private PRECISION = 1e18;

    // Start and end time of pool.
    uint256 public startTime; // The block number when emission starts.
    uint256 public endTime; // The block number when emission ends.

    // IERC721Enumerable interface.
    /// @dev needed to check if a NFT collection is Enumerable.
    bytes4 private constant _INTERFACE_ID_ERC721ENUMERABLE = 0x780e9d63;

    // Pool initialized.
    bool initialized;

    /**
     * @notice Initialize the pool with the given `_collection`, `_rewardTokenPrimary`, and `_rewardTokenSecondary`.
     * @param _collection The address of the NFT collection to use for the pool.
     * @param _rewardTokenPrimary The address of the primary reward token.
     * @param _rewardTokenSecondary The address of the secondary reward token.
     * @dev This function initializes the pool by setting the NFT collection, the reward tokens,
     * and the pool information.
     * @notice Pool will not reward until syncReward has been called.
     * Reverts if the function has already been called, or if the given `_collection` does not support ERC721Enumerable.
     */
    function initializePool(
        IERC721Enumerable _collection,
        IERC20 _rewardTokenPrimary,
        IERC20 _rewardTokenSecondary
    ) public onlyOwner {
        require(!initialized, "Initialized!");
        require(checkIERC721EnumerableSupport(address(_collection)), "Not ERC721Enumerable!");
        initialized = true;
        // set tokens
        rewardTokenPrimary = _rewardTokenPrimary;
        rewardTokenSecondary = _rewardTokenSecondary;

        // staking pool
        poolInfo = PoolInfo({
            collection: _collection,
            lastRewardTime: block.timestamp,
            accRewardPerSharePrimary: 0,
            accRewardPerShareSecondary: 0
        });
    }

    /**
     * @notice Get the reward multiplier(seconds) for a given time range.
     * @param _from The start time of the range.
     * @param _to The end time of the range.
     * @dev This function calculates the reward multiplier for a given time range based on the `endTime` of the pool
     * and the given range.
     * @return The reward multiplier for the given time range.
     */
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= endTime) {
            return _to - _from;
        } else if (_from >= endTime) {
            return 0;
        } else {
            return endTime - _from;
        }
    }

    /**
     * @notice View the pending rewards for the given `_user`.
     * @param _user The address of the user to check.
     * @dev This function calculates the pending rewards for the given user based on the current pool reward variables
     * and the user's staked balance.
     * @return The amount of primary and secondary rewards pending for the given user.
     */
    function pendingReward(address _user) public view returns (uint256, uint256) {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[_user];

        uint256 accRewardPerSharePrimary = pool.accRewardPerSharePrimary;
        uint256 accRewardPerShareSecondary = pool.accRewardPerShareSecondary;
        uint256 totalStaked = pool.collection.balanceOf(address(this));

        if (
            block.timestamp > pool.lastRewardTime && // is after last reward!
            totalStaked != 0 // has supply!
        ) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 rewardPrimary = multiplier * rewardPerSecondPrimary;
            uint256 rewardSecondary = multiplier * rewardPerSecondSecondary;

            accRewardPerSharePrimary = accRewardPerSharePrimary + ((rewardPrimary * PRECISION) / totalStaked);
            accRewardPerShareSecondary = accRewardPerShareSecondary + ((rewardSecondary * (PRECISION)) / (totalStaked));
        }

        uint256 pendingPrimary = ((user.amount * accRewardPerSharePrimary) / PRECISION) - user.rewardDebtPrimary;
        uint256 pendingSecondary = ((user.amount * accRewardPerShareSecondary) / PRECISION) -
            (user.rewardDebtSecondary);

        return (pendingPrimary, pendingSecondary);
    }

    /**
     * @notice Update the reward variables of the pool.
     * @dev This function is called to update the reward variables of the pool based on the elapsed time since the last
     * reward update.
     * If there is no staked balance, the function updates the `lastRewardTime` and returns.
     */
    function updatePool() public {
        PoolInfo storage pool = poolInfo;
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 totalStaked = pool.collection.balanceOf(address(this));
        if (totalStaked == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        // Calculate reward since last update.
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 rewardPrimary = multiplier * rewardPerSecondPrimary;
        uint256 rewardSecondary = multiplier * rewardPerSecondSecondary;

        // Update pool.
        pool.accRewardPerSharePrimary = pool.accRewardPerSharePrimary + ((rewardPrimary * PRECISION) / totalStaked);
        pool.accRewardPerShareSecondary =
            pool.accRewardPerShareSecondary +
            ((rewardSecondary * PRECISION) / totalStaked);
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * @notice Deposit an NFT with the given `_tokenId` into the pool for the caller.
     * @param _tokenId The ID of the token to deposit.
     * @dev This function is non-reentrant and can only be called if the contract is initialized and the user has
     * approved the contract to spend their NFT.
     * If the user has a pending reward, the reward is transferred to the user and a {Claim} event is emitted.
     * Emits a {Deposit} event indicating the address of the caller and the ID of the token that was deposited.
     * Reverts if the contract is not initialized or the user has not approved the contract to spend their NFT.
     */
    function deposit(uint256 _tokenId) public nonReentrant {
        require(initialized, "Not initialized!");
        PoolInfo storage pool = poolInfo;

        // Ensure the user has approved the contract to spend their NFT.
        require(pool.collection.isApprovedForAll(address(msg.sender), address(this)), "Need allowance!");

        updatePool();

        UserInfo storage user = userInfo[msg.sender];

        // Check for and transfer user pending reward.
        if (user.amount > 0) {
            // does user have pending primary reward token
            uint256 pendingPrimary = ((user.amount * pool.accRewardPerSharePrimary) / PRECISION) -
                user.rewardDebtPrimary;
            if (pendingPrimary > 0) {
                rewardTokenPrimary.safeTransfer(address(msg.sender), pendingPrimary);
            }
            // does user have pending secondary reward token
            uint256 pendingSecondary = ((user.amount * pool.accRewardPerShareSecondary) / PRECISION) -
                user.rewardDebtSecondary;
            if (pendingSecondary > 0) {
                rewardTokenSecondary.safeTransfer(address(msg.sender), pendingSecondary);
            }

            emit Claim(address(msg.sender), pendingPrimary, pendingSecondary);
        }

        // Transfer the NFT to the contract.
        pool.collection.safeTransferFrom(msg.sender, address(this), _tokenId);
        user.amount += 1;
        user.tokenIds.push(_tokenId);
        user.rewardDebtPrimary = (user.amount * pool.accRewardPerSharePrimary) / PRECISION;
        user.rewardDebtSecondary = (user.amount * pool.accRewardPerShareSecondary) / PRECISION;

        emit Deposit(msg.sender, _tokenId);
    }

    /**
     * @notice Deposit an array of tokens with given `_tokenIds` of the caller into the pool.
     * @param _tokenIds An array of token IDs to deposit.
     * @dev This function iterates over the user tokens and calls `deposit` for each token.
     */
    function depositTokens(uint256[] memory _tokenIds) public {
        uint256 numberOfTokens = _tokenIds.length;

        // Iterate over user tokens and deposit each token.

        for (uint256 i = 0; i < numberOfTokens; i++) {
            deposit(_tokenIds[i]);
        }
    }

    /**
     * @notice Deposit all owned tokens of the caller into the pool.
     * @dev This function iterates over the user tokens and calls `deposit` for each token.
     */
    function depositAll() public {
        IERC721Enumerable collection = poolInfo.collection;
        uint256 userBalance = poolInfo.collection.balanceOf(msg.sender);

        // Iterate over user tokens and deposit each token.
        for (uint256 i = 0; i < userBalance; i++) {
            uint256 tokenId = collection.tokenOfOwnerByIndex(msg.sender, 0);
            deposit(tokenId);
        }
    }

    /**
     * @notice Withdraw a deposited token with the given `_tokenId` of the caller.
     * @param _tokenId The ID of the token to withdraw.
     * @dev This function is non-reentrant and can only be called by the owner of the token.
     * Emits a {Withdraw} event indicating the address of the caller and the ID of the token that was withdrawn.
     * If the user had a pending reward, emits a {Claim} event indicating the address of the caller, the amount of
     * primary reward tokens claimed, and the amount of secondary reward tokens claimed.
     * Reverts if the caller is not the owner of the token.
     */
    function withdraw(uint256 _tokenId) public nonReentrant {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        require(_isInArray(user.tokenIds, _tokenId), "Not owner!");

        updatePool();

        // Check for and transfer user pending reward.
        uint256 pendingPrimary = ((user.amount * pool.accRewardPerSharePrimary) / PRECISION) - user.rewardDebtPrimary;

        if (pendingPrimary > 0) {
            rewardTokenPrimary.safeTransfer(address(msg.sender), pendingPrimary);
        }

        uint256 pendingSecondary = ((user.amount * pool.accRewardPerShareSecondary) / PRECISION) -
            user.rewardDebtSecondary;

        if (pendingSecondary > 0) {
            rewardTokenSecondary.safeTransfer(address(msg.sender), pendingSecondary);
        }

        // Emit claim if user had was rewarded.
        if (pendingPrimary > 0 || pendingSecondary > 0) {
            emit Claim(address(msg.sender), pendingPrimary, pendingSecondary);
        }

        // Update user token info.
        user.amount -= 1;
        user.tokenIds = _removeValueFromArray(user.tokenIds, _tokenId);

        // transfer nft
        pool.collection.safeTransferFrom(address(this), msg.sender, _tokenId);

        // update reward debt
        user.rewardDebtPrimary = (user.amount * pool.accRewardPerSharePrimary) / PRECISION;
        user.rewardDebtSecondary = (user.amount * pool.accRewardPerShareSecondary) / PRECISION;

        emit Withdraw(msg.sender, _tokenId);
    }

    /**
     * @notice Withdraw deposited tokens with given `_tokenIds` of the caller.
     * @param _tokenIds An array of token IDs to withdraw.
     * @dev This function iterates over the user tokens and calls `withdraw` for each token.
     */
    function withdrawTokens(uint256[] memory _tokenIds) public {
        uint256 numberOfTokens = _tokenIds.length;

        // Iterate over user tokens and withdraw each token.

        for (uint256 i = 0; i < numberOfTokens; i++) {
            withdraw(_tokenIds[i]);
        }
    }

    /**
     * @notice Withdraw all deposited tokens of the caller.
     * @dev This function iterates over the user tokens and calls `withdraw` for each token.
     */
    function withdrawAll() public {
        uint256[] memory userTokens = userInfo[address(msg.sender)].tokenIds;
        uint256 numberOfTokens = userTokens.length;

        // Iterate over user tokens and withdraw each token.

        for (uint256 i = 0; i < numberOfTokens; i++) {
            withdraw(userTokens[i]);
        }
    }

    /**
     * @notice Withdraw all deposited tokens of the caller in case of an emergency.
     * @dev This function can be called by anyone
     * and does not use the reentrancy guard because the amount is set to zero.
     * Emits a {EmergencyWithdraw} event indicating the address of the caller
     * and an array of token IDs that were withdrawn.
     */
    function emergencyWithdraw() public {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];

        uint256[] memory userTokens = user.tokenIds;
        uint256 numberOfTokens = user.amount;

        for (uint256 i = 0; i < numberOfTokens; i++) {
            pool.collection.safeTransferFrom(
                address(this),
                msg.sender,
                userTokens[i] // we copied the array so it will not decrement
            );
        }

        // Update user info.
        user.amount = 0;
        delete user.tokenIds;
        user.rewardDebtPrimary = 0;
        user.rewardDebtSecondary = 0;

        emit EmergencyWithdraw(msg.sender, userTokens);
    }

    /**
     * @notice Claim the pending reward for the caller.
     * @dev This function is non-reentrant.
     * @dev we need a claim function, as we cannot deposit 0 tokens or withdraw 0 tokens to claim when using nfts.
     * Emits a {Claim} event indicating the address of the caller, the amount of primary reward tokens claimed, and the
     * amount of secondary reward tokens claimed.
     * Reverts if the user has no balance.
     */
    function claim() public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount > 0, "No balance!");

        PoolInfo storage pool = poolInfo;

        updatePool();

        // Check for and transfer user pending reward.
        uint256 pendingPrimary = ((user.amount * pool.accRewardPerSharePrimary) / PRECISION) - user.rewardDebtPrimary;
        if (pendingPrimary > 0) {
            rewardTokenPrimary.safeTransfer(address(msg.sender), pendingPrimary);
        }
        uint256 pendingSecondary = ((user.amount * pool.accRewardPerShareSecondary) / PRECISION) -
            user.rewardDebtSecondary;
        if (pendingSecondary > 0) {
            rewardTokenSecondary.safeTransfer(address(msg.sender), pendingSecondary);
        }

        // update reward debt
        user.rewardDebtPrimary = (user.amount * pool.accRewardPerSharePrimary) / PRECISION;
        user.rewardDebtSecondary = (user.amount * pool.accRewardPerShareSecondary) / PRECISION;

        emit Claim(msg.sender, pendingPrimary, pendingSecondary);
    }

    /**
     * @notice Synchronize rewards by transferring `_amountPrimary` and `_amountSecondary` tokens from the caller to
     * the contract and updating the reward rate for both tokens for `_timeInSeconds` seconds.
     * @dev This function can only be called by the owner of the contract.
     * @param _amountPrimary The amount of primary reward tokens to transfer.
     * @param _amountSecondary The amount of secondary reward tokens to transfer.
     * @param _timeInSeconds The duration of the reward period in seconds.
     * Emits a {SyncedReward} event indicating the amount of primary reward tokens, secondary reward tokens, and the
     * duration of the reward period.
     */
    function syncReward(uint256 _amountPrimary, uint256 _amountSecondary, uint256 _timeInSeconds) external onlyOwner {
        require(block.timestamp >= endTime, "Too early!");

        updatePool();

        rewardTokenPrimary.transferFrom(address(msg.sender), address(this), _amountPrimary);
        rewardTokenSecondary.transferFrom(address(msg.sender), address(this), _amountSecondary);
        rewardPerSecondPrimary = _amountPrimary / _timeInSeconds;
        rewardPerSecondSecondary = _amountSecondary / _timeInSeconds;
        startTime = block.timestamp;
        endTime = block.timestamp + _timeInSeconds;

        emit SyncedReward(_amountPrimary, _amountSecondary, _timeInSeconds);
    }

    /**
     * @notice Get an array of token IDs owned by `_user`.
     * @param _user The address of the user.
     * @return tokenIds An array of token IDs owned by `_user`.
     */
    function tokensOf(address _user) external view returns (uint256[] memory tokenIds) {
        return userInfo[_user].tokenIds;
    }

    /**
     * @notice Checks if an element uint256 `value` is in an `array`.
     * @dev This function is private and can only be called within the contract.
     * @param array The array in which the element will be searched.
     * @param value The value of the element to be searched.
     * @return A boolean indicating whether the `value` is in the `array`.
     */
    function _isInArray(uint256[] memory array, uint256 value) private pure returns (bool) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Removes an element `value` from the `array` and returns a new array.
     * @dev This function is private and can only be called within the contract.
     * @param array The array from which the element will be removed.
     * @param value The value of the element to be removed.
     * @return A new array with the `value` removed.
     */
    function _removeValueFromArray(uint256[] memory array, uint256 value) private pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](array.length - 1);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] != value) {
                result[resultIndex] = array[i];
                resultIndex++;
            }
        }

        return result;
    }

    // ERC721 related functions.
    /// @dev Standard function required for the contract to receive NFTs.
    /// @dev Does not compile if you remove the unused parameters.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) public view returns (bytes4) {
        // Verify that the token was transferred by the token owner
        require(msg.sender == address(poolInfo.collection), "Can only receive tokens from the token contract");
        return IERC721Receiver.onERC721Received.selector;
    }

    //  Checks if a NFT collection supports ERC721Enuemrable.
    function checkIERC721EnumerableSupport(address target) private view returns (bool) {
        IERC721 targetContract = IERC721(target);
        return targetContract.supportsInterface(_INTERFACE_ID_ERC721ENUMERABLE);
    }
    // END OF CONTRACT
}
