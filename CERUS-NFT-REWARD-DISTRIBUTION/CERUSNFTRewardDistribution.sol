/**
 * @title CERUS NFT Staking
 * @dev Allows users to deposit CERUS NFTs and earn rewards in METIS and CERUS tokens.
 *
 * DEFAULT_ADMIN_ROLE can:
 * - add nft collections, but not remove as we want user to
 *   always be able to withdraw their tokens.
 * - toggle collectionReceivesReward
 * - set cerus token address.
 * - retrieve unused tokens from the contract.
 *
 * REWARDER_ROLE can:
 * - Add reward to be distributed to the users based on their nft balance.
 *
 * Users can:
 * - deposit and withdraw nft tokens.
 * - claim reward.
 */

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract CERUSNFTRewardDistribution is
    AccessControl,
    IERC721Receiver,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // EVENTS
    event CerusAddress(address cerusAddress);
    event CollectionAdded(address collection);
    event Deposit(
        address indexed user,
        address indexed collection,
        uint256 tokenId
    );
    event Withdraw(
        address indexed user,
        address indexed collection,
        uint256 tokenId
    );
    event EmergencyWithdraw(address indexed user);
    event RewardAdded(
        address indexed collection,
        uint256 amountMetis,
        uint256 amountCerus
    );
    event Reward(
        address indexed user,
        address indexed collection,
        uint256[] tokenIds,
        uint256 amountMetis,
        uint256 amountCerus
    );
    event Claim(address user, uint256 amountMetis, uint256 amountCerus);
    event RetrieveToken(address token, uint256 amount);

    // ACCESS ROLES
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    // COLLECTIONS
    address[] private _collections; /// @dev users always need to be able to withdraw their tokens
    mapping(address => bool) public collectionReceivesReward;

    // REWARDS
    struct PendingReward {
        uint256 time; // block timestamp
        address collection; // collection address
        uint256 amountMetis; // amount of metis
        uint256 amountCerus; // amount of cerus
        address[] users; // array of users to receive reward
    }
    PendingReward[] private pendingRewards; // array of pending rewards

    // USERS
    struct UserInfo {
        uint256 claimableMetis; // Reward that user can claim
        uint256 claimableCerus; // Reward that user can claim
        uint256 balance; // NFT counter
        mapping(address => uint256[]) tokens; // User deposited nft token ids by collection address
    }
    mapping(address => UserInfo) private users; // Maps user info to addresses
    address[] private _userAddresses; // Array of user addresses for reward distribution

    // ADDRESSES
    address public cerus = address(0); /// @dev Not deployed yet! See setCerus method.
    address public metis = 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000; // the metis erc20 token address
    address public treasury = 0xa9849eC5db1DD4cd5eB25d2180a64f21A45e7bD8; // project gnosis safe treausry address

    // BOOLEANS
    bool isCerusSet; /// @dev Determines if the cerus token address can be set.

    // CONSTRUCTOR
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REWARDER_ROLE, msg.sender);
        _grantRole(REWARDER_ROLE, treasury);
    }

    // ADDERS & SETTERS
    /**
     * @notice Set the CERUS token address.
     * @dev Can only be called by DEFAULT_ADMIN_ROLE and only once.
     * @param cerusAddress The address of the CERUS token contract.
     */
    function setCerus(address cerusAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!isCerusSet, "CERUS already set!");

        cerus = cerusAddress;
        isCerusSet = true;

        emit CerusAddress(cerusAddress);
    }

    /**
     * @notice Add a new NFT collection to the staking contract.
     * @dev Can only be called by DEFAULT_ADMIN_ROLE.
     * @param collection The address of the NFT collection contract.
     */
    function addCollection(address collection)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            !(_addressIsInArray(_collections, collection)),
            "Collection exists!"
        );

        _collections.push(collection);
        collectionReceivesReward[collection] = true;

        emit CollectionAdded(collection);
    }

    /**
     * @notice Set the reward eligibility of a collection.
     * @dev Can only be called by DEFAULT_ADMIN_ROLE.
     * @param collection The address of the NFT collection contract.
     * @param state The reward eligibility state (true for eligible, false for ineligible).
     */
    function setCollectionReceivesReward(address collection, bool state)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        collectionReceivesReward[collection] = state;
    }

    /**
     * @notice Add rewards to a specific NFT collection.
     * @dev Can only be called by REWARDER_ROLE.
     * @param collection The address of the NFT collection contract.
     * @param amountMetis The amount of METIS tokens to be rewarded.
     * @param amountCerus The amount of CERUS tokens to be rewarded.
     */
    function addReward(
        address collection,
        uint256 amountMetis,
        uint256 amountCerus
    ) external onlyRole(REWARDER_ROLE) {
        // Check amounts
        require(amountMetis > 0 || amountCerus > 0, "No reward!");
        /// @dev In case of cerus reward ensure that cerus address is set!
        if (amountCerus > 0) {
            require(isCerusSet, "Cerus address not set!");
        }
        // Check if there is anything staked
        uint256 collectionBalance = IERC721Enumerable(collection).balanceOf(
            address(this)
        );
        require(collectionBalance > 0, "No users!");

        // Receive METIS
        if (amountMetis > 0) {
            require(
                IERC20(metis).transferFrom(
                    address(msg.sender),
                    address(this),
                    amountMetis
                ),
                "Transfer failed!"
            );
        }

        // Receive CERUS
        if (amountCerus > 0) {
            require(
                IERC20(cerus).transferFrom(
                    address(msg.sender),
                    address(this),
                    amountCerus
                ),
                "Transfer failed!"
            );
        }

        // Add to pendingRewards
        PendingReward memory newReward; // = new PendingReward();
        newReward.time = block.timestamp;
        newReward.collection = collection;
        newReward.amountMetis = amountMetis;
        newReward.amountCerus = amountCerus;

        // make array of users with collection balance
        address[] memory usersWithCollectionTokens = new address[](0);

        for (uint256 i = 0; i < _userAddresses.length; i++) {
            address userAddress = _userAddresses[i];

            if (tokensOf(userAddress, collection).length > 0) {
                usersWithCollectionTokens = _addAddressToArray(
                    usersWithCollectionTokens,
                    userAddress
                );
            }
        }
        newReward.users = usersWithCollectionTokens;

        // add reward
        pendingRewards.push(newReward);

        emit RewardAdded(collection, amountMetis, amountCerus);
    }

    // DEPOSIT
    /**
     * @notice Deposit a specific NFT into the staking contract.
     * @param collection The address of the NFT collection contract.
     * @param tokenId The ID of the NFT to deposit.
     */
    function deposit(address collection, uint256 tokenId) public nonReentrant {
        // Check if collection exists and in use.
        require(
            _addressIsInArray(_collections, collection) &&
                collectionReceivesReward[collection],
            "Collection unknown!"
        );

        // Ensure the user has approved the contract to spend their NFT.
        require(
            IERC721Enumerable(collection).isApprovedForAll(
                msg.sender,
                address(this)
            ),
            "Need allowance!"
        );

        _claim(address(msg.sender));

        // Transfer the NFT to the contract.
        IERC721Enumerable(collection).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        // Check if user exists in _userAddresses if not add.
        if ((!_addressIsInArray(_userAddresses, msg.sender))) {
            _userAddresses.push(address(msg.sender));
        }

        // Add token to user info.
        users[msg.sender].tokens[collection].push(tokenId);
        users[msg.sender].balance += 1;

        // Emit event.
        emit Deposit(address(msg.sender), collection, tokenId);
    }

    /**
     * @notice Deposit all NFTs from a specific collection owned by the caller.
     * @param collection The address of the NFT collection contract.
     */
    function depositCollection(address collection) public {
        uint256 user_balance = IERC721Enumerable(collection).balanceOf(
            msg.sender
        );
        // Iterate over user tokens and deposit each token.
        for (uint256 i = 0; i < user_balance; i++) {
            uint256 tokenId = IERC721Enumerable(collection).tokenOfOwnerByIndex(
                msg.sender,
                0
            );

            deposit(collection, tokenId);
        }
    }

    /**
     * @notice Deposit all NFTs from all collections owned by the caller.
     */
    function depositAll() external {
        // iterate over all collections and deposit all user tokens of each collection.
        for (uint256 i = 0; i < _collections.length; i++) {
            address collection = _collections[i];

            depositCollection((collection));
        }
    }

    // WITHDRAW
    /**
     * @notice Withdraw all NFTs and claim rewards.
     */
    function withdrawAll() external {
        _claim(address(msg.sender));
        _withdrawAll();
    }

    /**
     * @notice Withdraw all NFTs of a specific collection and claim rewards.
     * @param collection The address of the NFT collection contract.
     */
    function withdrawCollection(address collection) public {
        _claim(address(msg.sender));
        _withdrawCollection(address(msg.sender), collection);
    }

    /**
     * @notice Withdraw a specific NFT and claim rewards.
     * @param collection The address of the NFT collection contract.
     * @param tokenId The ID of the NFT to withdraw.
     */
    function withdraw(address collection, uint256 tokenId) public {
        require(
            _addressIsInArray(_collections, collection),
            "Collection unknown!"
        );
        _claim(address(msg.sender));
        _withdraw(collection, tokenId);
    }

    /**
     * @dev Internal function to withdraw all user's deposited NFTs from all collections.
     */
    function _withdrawAll() private {
        // iterate over all collections and withdraw all user tokens of each collection.
        for (uint256 i = 0; i < _collections.length; i++) {
            address collection = _collections[i];
            _withdrawCollection(address(msg.sender), collection);
        }
    }

    /**
     * @dev Internal function to withdraw user's deposited NFTs from a specific collection.
     * @param user The user address to withdraw NFTs for.
     * @param collection The address of the NFT collection to withdraw from.
     */
    function _withdrawCollection(address user, address collection) private {
        require(
            _addressIsInArray(_collections, collection),
            "Collection unknown!"
        );
        uint256 userTokenCount = users[user].tokens[collection].length;

        if (userTokenCount > 0) {
            for (uint256 j = 0; j < userTokenCount; j++) {
                uint256 tokenId = users[user].tokens[collection][0]; // index 0 as shrinks
                _withdraw(collection, tokenId);
            }

            delete users[user].tokens[collection];
        }
    }

    /**
     * @dev Internal function to withdraw a specific NFT from the contract.
     * We don't claim rewawrd here as all top level calling functions already claim.
     * @param collection The address of the NFT collection.
     * @param tokenId The ID of the NFT to withdraw.
     */
    function _withdraw(address collection, uint256 tokenId)
        private
        nonReentrant
    {
        uint256[] memory user_tokens = users[msg.sender].tokens[collection];
        require(_isInArray(user_tokens, tokenId), "Not owner!");

        users[msg.sender].tokens[collection] = _removeValueFromArray(
            user_tokens,
            tokenId
        );
        users[msg.sender].balance -= 1;

        IERC721Enumerable(collection).safeTransferFrom(
            address(this),
            msg.sender,
            tokenId
        );

        emit Withdraw(msg.sender, collection, tokenId);
    }

    /**
     * @dev Allows a user to withdraw all their deposited NFTs without claiming rewards.
     * The difference between this and normal withdraw is NOT calling _claim.
     * @notice Calling this method will withdraw all nfts for the users calling without claiming reward.
     * We do NOT reset user pending. they should still be able to claim their reward when possible.
     * Used in case of an emergency.
     */
    function emergencyWithdraw() external {
        _withdrawAll(); /// @dev EMERGENCY!

        emit EmergencyWithdraw(address(msg.sender));
    }

    // CLAIM AND REWARD RELEASE

    /**
     * @dev Distributes pending rewards for a specific user.
     * @param user The address of the user to distribute rewards for.
     */
    function distributePendingReward(address user) external nonReentrant {
        _distribute(user);
    }

    /**
     * @dev Distributes pending rewards to all users.
     */
    function distributePendingRewardToAllUsers() external nonReentrant {
        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _distribute(_userAddresses[i]);
        }
    }

    /**
     * @dev Internal function to distribute rewards for a specific user.
     * @param user The address of the user to distribute rewards for.
     */
    function _distribute(address user) private {
        uint256 numberOfRewards = pendingRewards.length;

        if (numberOfRewards > 0) {
            // check if user has reward
            for (uint256 i = 0; i < numberOfRewards; i++) {
                PendingReward storage reward = pendingRewards[i];
                bool hasReward = _addressIsInArray(reward.users, user);

                // Calculate user reward.
                if (hasReward) {
                    address collection = reward.collection;
                    uint256 numberOfUserTokens = users[user]
                        .tokens[collection]
                        .length;
                    uint256 perTokenShareMetis = reward.amountMetis /
                        numberOfUserTokens;
                    uint256 perTokenShareCerus = reward.amountCerus /
                        numberOfUserTokens;
                    uint256 totalRewardMetis = perTokenShareMetis *
                        numberOfUserTokens;
                    uint256 totalRewardCerus = perTokenShareCerus *
                        numberOfUserTokens;

                    // user vars
                    users[user].claimableMetis += totalRewardMetis;
                    users[user].claimableCerus += totalRewardCerus;

                    // remove user from reward array
                    pendingRewards[i].users = _removeAddressFromArray(
                        pendingRewards[i].users,
                        user
                    );
                    // remove reward if no users
                    if (pendingRewards[i].users.length == 0) {
                        _removeRewardAtIndex(i);
                        numberOfRewards -= 1;
                    }
                    // emit event
                    emit Reward(
                        user,
                        collection,
                        users[user].tokens[collection],
                        totalRewardMetis,
                        totalRewardCerus
                    );
                }
            }
        }
    }

    /**
     * @dev Allows a user to claim their pending rewards.
     */
    function claim() external nonReentrant {
        _claim(address(msg.sender));
    }

    /**
     * @dev Internal function to claim rewards for a specific user.
     * @param user The address of the user to claim rewards for.
     */
    function _claim(address user) private {
        _distribute(address(msg.sender));

        uint256 claimableMetis = users[user].claimableMetis;
        uint256 claimableCerus = users[user].claimableCerus;

        if (claimableMetis > 0 || claimableCerus > 0) {
            // transfer metis
            if (claimableMetis > 0) {
                // Reset user pedngin metis
                users[user].claimableMetis = 0;

                /// @dev Must send pending to user
                IERC20(metis).transfer(user, claimableMetis);
            }

            // transfer cerus
            if (claimableCerus > 0) {
                // Reset user peding cerus
                users[user].claimableCerus = 0;

                /// @dev Must send pending to user
                IERC20(cerus).transfer(user, claimableCerus);
            }

            // emit event
            emit Claim(msg.sender, claimableMetis, claimableCerus);
        }
    }

    // EXTERNAL & PUBLIC HELPER FUNCTIONS
    /**
     * @notice Returns the balance of the user's deposited NFTs.
     * @param user The address of the user.
     * @return balance The balance of the user's deposited NFTs.
     */
    function balanceOf(address user) external view returns (uint256) {
        uint256 balance = users[user].balance;

        return balance;
    }

    /**
     * @notice Returns the total balance of all users' deposited NFTs.
     * @return _totalBalance The total balance of all users' deposited NFTs.
     */
    function totalBalance() external view returns (uint256) {
        uint256 _totalBalance = 0;

        for (uint256 i = 0; i < _userAddresses.length; i++) {
            _totalBalance += users[_userAddresses[i]].balance;
        }

        return _totalBalance;
    }

    /**
     * @notice Returns the number of pending rewards.
     * @return numberOfRewards The number of pending rewards.
     */
    function numberOfPendingRewards()
        external
        view
        returns (uint256 numberOfRewards)
    {
        numberOfRewards = pendingRewards.length;
    }

    /**
     * @notice Returns the next pending reward's collection address and amounts for Metis and Cerus.
     * @return collection The collection address of the next reward.
     * @return amountMetis The amount of Metis tokens in the next reward.
     * @return amountCerus The amount of Cerus tokens in the next reward.
     */
    function nextReward()
        external
        view
        returns (
            address collection,
            uint256 amountMetis,
            uint256 amountCerus
        )
    {
        collection = pendingRewards[0].collection;
        amountMetis = pendingRewards[0].amountMetis;
        amountCerus = pendingRewards[0].amountCerus;
    }

    /**
     * @notice Returns an array of token IDs deposited by the user for a specific collection.
     * @param user The address of the user.
     * @param collection The address of the collection.
     * @return user_tokens An array of token IDs deposited by the user for the collection.
     */
    function tokensOf(address user, address collection)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory user_tokens = users[user].tokens[collection];
        return user_tokens;
    }

    /**
     * @notice Returns the user's unclaimed reward amounts for Metis and Cerus tokens.
     * @param user The address of the user.
     * @return unclaimedAmountMetis The amount of unclaimed Metis tokens for the user.
     * @return unclaimedAmountCerus The amount of unclaimed Cerus tokens for the user.
     */
    function unclaimedReward(address user)
        public
        view
        returns (uint256 unclaimedAmountMetis, uint256 unclaimedAmountCerus)
    {
        unclaimedAmountMetis = users[user].claimableMetis;
        unclaimedAmountCerus = users[user].claimableCerus;
    }

    /**
     * @notice Returns the user's unreleased reward amounts for Metis and Cerus tokens.
     * @param user The address of the user.
     * @return unreleasedAmountMetis The amount of unreleased Metis tokens for the user.
     * @return unreleasedAmountCerus The amount of unreleased Cerus tokens for the user.
     */
    function pendingRewardsUser(address user)
        public
        view
        returns (uint256 unreleasedAmountMetis, uint256 unreleasedAmountCerus)
    {
        for (uint256 i = 0; i < pendingRewards.length; i++) {
            bool hasReward = _addressIsInArray(pendingRewards[i].users, user);
            if (hasReward) {
                unreleasedAmountMetis +=
                    pendingRewards[i].amountMetis /
                    pendingRewards[i].users.length;
                unreleasedAmountCerus +=
                    pendingRewards[i].amountCerus /
                    pendingRewards[i].users.length;
            }
        }
    }

    /**
     * @notice Returns the total pending and claimable rewards for a user in Metis and Cerus tokens.
     * @param user The address of the user.
     * @return totalAmountMetis The total amount of pending and claimable Metis tokens for the user.
     * @return totalAmountCerus The total amount of pending and claimable Cerus tokens for the user.
     */
    function pendingAndClaimableReward(address user)
        external
        view
        returns (uint256 totalAmountMetis, uint256 totalAmountCerus)
    {
        (
            uint256 unreleasedAmountMetis,
            uint256 unreleasedAmountCerus
        ) = pendingRewardsUser(user);
        (
            uint256 unclaimedAmountMetis,
            uint256 unclaimedAmountCerus
        ) = unclaimedReward(user);
        totalAmountMetis = unreleasedAmountMetis + unclaimedAmountMetis;
        totalAmountCerus = unreleasedAmountCerus + unclaimedAmountCerus;
    }

    /**
     * @notice Returns the pending reward amounts for a user in a specific collection in Metis and Cerus tokens.
     * @param user The address of the user.
     * @param collection The address of the collection.
     * @return amountMetis The amount of pending Metis tokens for the user in the specific collection.
     * @return amountCerus The amount of pending Cerus tokens for the user in the specific collection.
     */
    function pendingRewardCollection(address user, address collection)
        external
        view
        returns (uint256 amountMetis, uint256 amountCerus)
    {
        for (uint256 i = 0; i < pendingRewards.length; i++) {
            if (pendingRewards[i].collection == collection) {
                if (_addressIsInArray(pendingRewards[i].users, user)) {
                    uint256 numberOfTokens = IERC721Enumerable(collection)
                        .balanceOf(address(this));
                    uint256 perTokenShareMetis = pendingRewards[i].amountMetis /
                        numberOfTokens;
                    uint256 perTokenShareCerus = pendingRewards[i].amountCerus /
                        numberOfTokens;

                    amountMetis =
                        users[user].tokens[collection].length *
                        perTokenShareMetis;
                    amountCerus =
                        users[user].tokens[collection].length *
                        perTokenShareCerus;
                }
                break;
            }
        }
    }

    /**
     * @notice Returns an array of collection addresses.
     * @return _collections An array of collection addresses.
     */
    function collections() external view returns (address[] memory) {
        return _collections;
    }

    /**
     * @notice Returns an array of user addresses.
     * @return _userAddresses An array of user addresses.
     */
    function userAddresses() external view returns (address[] memory) {
        return _userAddresses;
    }

    /**
     * @notice Retrieves ERC20 tokens (excluding Metis and Cerus) from the contract and transfers them to a recipient.
     * @param tokenAddress The address of the ERC20 token to be retrieved.
     * @param recipient The address of the recipient who will receive the retrieved tokens.
     * @dev Requires the caller to have the DEFAULT_ADMIN_ROLE.
     */
    function retrieveTokens(address tokenAddress, address recipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(tokenAddress != metis, "Can't retrieve metis"); /// @notice Not allowed because it is the reward token!
        require(tokenAddress != cerus, "Can't retrieve cerus"); /// @notice Not allowed because it is the reward token!
        /// @dev Check below is just for security should not be possible as nfts operate by id.
        require(
            !_addressIsInArray(_collections, tokenAddress),
            "Cannot retrieve from collections!"
        );
        uint256 balance = IERC20(tokenAddress).balanceOf(address(this));
        require(balance > 0, "No balance!");
        require(
            IERC20(tokenAddress).transfer(recipient, balance),
            "Token transfer failed!"
        );

        emit RetrieveToken(tokenAddress, balance);
    }

    // PRIVATE HELPER FUNCTIONS
    /**
     * @notice Checks if a value is present in an array of uint256 values.
     * @param array The array to search in.
     * @param value The value to search for.
     * @return True if the value is present in the array, false otherwise.
     */
    function _isInArray(uint256[] memory array, uint256 value)
        private
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Checks if an address is present in an array of addresses.
     * @param array The array to search in.
     * @param element The address to search for.
     * @return True if the address is present in the array, false otherwise.
     */
    function _addressIsInArray(address[] memory array, address element)
        private
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == element) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Removes a value from an array of uint256 values.
     * @param array The array to remove the value from.
     * @param value The value to remove.
     * @return A new array with the value removed.
     */
    function _removeValueFromArray(uint256[] memory array, uint256 value)
        private
        pure
        returns (uint256[] memory)
    {
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

    /**
     * @notice Adds an address to an array of addresses.
     * @param array The array to add the address to.
     * @param _address The address to add.
     * @return A new array with the address added.
     */
    function _addAddressToArray(address[] memory array, address _address)
        private
        pure
        returns (address[] memory)
    {
        address[] memory newArray = new address[](array.length + 1);
        for (uint256 i = 0; i < array.length; i++) {
            newArray[i] = array[i];
        }
        newArray[array.length] = _address;
        return newArray;
    }

    /**
     * @notice Removes an address from an array of addresses.
     * @param array The array to remove the address from.
     * @param value The address to remove.
     * @return A new array with the address removed.
     */
    function _removeAddressFromArray(address[] memory array, address value)
        private
        pure
        returns (address[] memory)
    {
        address[] memory result = new address[](array.length - 1);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] != value) {
                result[resultIndex] = array[i];
                resultIndex++;
            }
        }

        return result;
    }

    /**
     * @notice Removes a reward from the pendingRewards array at a given index.
     * @param index The index of the reward to remove.
     * @dev Requires the index to be within the bounds of the pendingRewards array.
     */
    function _removeRewardAtIndex(uint256 index) private {
        require(index < pendingRewards.length, "Index out of bounds");

        // If the element to remove is not the last one, swap it with the last one
        if (index < pendingRewards.length - 1) {
            pendingRewards[index] = pendingRewards[pendingRewards.length - 1];
        }

        // Remove the last element (or the original element if it was the last one)
        pendingRewards.pop();
    }

    // REQUIRED FUNCTIONS
    /**
     * @notice Handles the receipt of an ERC721 token by the staking pool using safeTransfer.
     * @dev This function is required by the ERC721 standard and called by the ERC721 contract.
     * @param operator The address that initiated the transfer.
     * @param from The address that previously owned the token.
     * @param tokenId The ID of the token being transferred.
     * @param data Additional data sent with the transfer.
     * @return A bytes4 selector that indicates the successful receipt of the token
     *           (IERC721Receiver.onERC721Received.selector).
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) public view returns (bytes4) {
        // Verify that the token was transferred by the token owner
        /// @notice since we use multiple collections we check if it is registered instead of
        // checking against a certain address
        require(_addressIsInArray(_collections, msg.sender));
        // require(
        //     msg.sender == address(nftCollection),
        //     "Can only receive tokens from the token contract"
        // );
        // Handle the received token
        // stake(tokenId);
        // Return the ERC721_RECEIVED value
        return IERC721Receiver.onERC721Received.selector;
    }

    // END CONTRACT
}
