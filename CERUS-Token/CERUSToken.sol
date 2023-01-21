//                                   %@
//                               @@@@@%
//                            %@@@@@@@
//                  @@@     /@@@@@@@
//                 &@@@@   @@@@@@@
//                 @@@@@  %@@@@%
//                 @@@@@ #@            (,/
//         @@@     @@@@@@ *@@@@@@@@@..........,,
//         @@@@&    @@@@@@@@@@@@@@..................
//         @@@@@(   @@,#&@%(  (......................,#
//          @@@@@  @ .,................................,/
//    @@    */..@@........................,..........,.......
//   @@@@@  . @@@.......................... ...,......../ ....,
//   (@@@@@..( @#.........................,       ....(
//    @@@@@( &@(.........,, ..................,,  ,.(
//     @@@@@@&......,@@@@@@(..,,....,( .   ...,.
//      #@@@(.....@@@@@@#      ....( .......
//        @#@...@@@/           .,.
//       @( ,...              #..
//      @(  ....,#(/,...,,..............,.,,...*/(#

//      @@@@@@@@   @@@@@@@@@  @@@@@@@@  @@@@   @@@  @@@@@@@@@
//     @@@        @@@        @@    @@@  @@@   @@@  @@@
//    @@@        @@@@@@@@@@ @@@@@@@@@  @@@   @@@ @@@@@@@@@@
//   @@@        @@@        @@@   @@@  @@@   @@@&       @@@
//    @@@@@@   @@@@@@@@@@ @@@    @@@   @@@@@@   @@@@@@@%
//
// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/IUniswapV2Pair.sol";

contract CERUSToken is ERC20("CERUS Token", "CERUS"), ERC20Burnable, Ownable {
    using Address for address;

    // Events
    event Tax(uint256 tax);
    event TaxDistributor(address taxDistributor);
    event Whitelist(address proxy, bool state);

    // Supply and burn
    uint256 public constant INITIAL_SUPPLY = 5000000 * 10**18; /// @notice 5 Million max. supply.
    uint256 public constant MAX_BURNED = 1000000 * 10**18; /// @notice Max. 1 million CERUS burned.

    // Tax
    uint256 public constant PRECISION = 10000; /// @dev 100.00% (we calculate percentage times 100)
    uint256 public constant MAX_TAX = 500; // 5%
    uint256 public tax = 500; // Initial tax. (percentage * 100 for precision).
    address public taxDistributor; /// @notice distributes tax as per whitepaper.

    // Router whitelist.
    mapping(address => bool) public whitelisted;

    /// @notice We mint all tokens for distribution as per whitepaper.
    constructor() {
        _mint(address(msg.sender), INITIAL_SUPPLY);
    }

    // OVERRIDES
    // Transfer with  sales tax
    function transfer(address _to, uint256 _amount)
        public
        override
        returns (bool)
    {
        uint256 _tax = tax;
        address _taxDistributor = taxDistributor;
        address sender = msg.sender;

        if (
            _taxDistributor != address(0) &&
            _tax > 0 &&
            _isPair(_to) &&
            !whitelisted[sender]
        ) {
            // Tax!
            uint256 calculatedTax = (_amount * _tax) / PRECISION;
            uint256 amountTaxed = _amount - calculatedTax;

            _transfer(sender, _taxDistributor, calculatedTax);
            _transfer(sender, _to, amountTaxed);
        } else {
            // No tax!
            _transfer(sender, _to, _amount);
        }

        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) public override returns (bool) {
        address spender = _msgSender();

        if (
            taxDistributor != address(0) &&
            tax > 0 &&
            _isPair(_to) &&
            !whitelisted[spender]
        ) {
            // Tax transfer.
            uint256 calculatedTax = (_amount * tax) / PRECISION;
            uint256 amountTaxed = _amount - calculatedTax;

            _spendAllowance(_from, spender, _amount);
            _transfer(_from, taxDistributor, calculatedTax);
            _transfer(_from, _to, amountTaxed);

            return true;
        } else {
            // No tax transfer.
            _spendAllowance(_from, spender, _amount);
            _transfer(_from, _to, _amount);

            return true;
        }
    }

    function burn(uint256 _amount) public override {
        require(totalBurned() + _amount <= MAX_BURNED, "burn: max burn!");

        _burn(msg.sender, _amount);
    }

    function burnFrom(address _account, uint256 _amount) public override {
        require(totalBurned() + _amount <= MAX_BURNED, "burn: max burn!");

        address spender = _msgSender();

        _spendAllowance(_account, spender, _amount);
        _burn(_account, _amount);
    }

    // SETTERS & HELPERS
    function totalBurned() public view returns (uint256) {
        uint256 burned = INITIAL_SUPPLY - totalSupply();

        return burned;
    }

    function setTaxDistributor(address _taxDistributor) external onlyOwner {
        require(taxDistributor == address(0), "Tax distributor set!");

        taxDistributor = _taxDistributor;

        emit TaxDistributor(_taxDistributor);
    }

    function setTax(uint256 _tax) external onlyOwner {
        require(_tax <= MAX_TAX, "Tax: too high!");
       
        tax = _tax;

        emit Tax(_tax);
    }

    function whitelist(address _proxy, bool _newState) external onlyOwner {
        whitelisted[_proxy] = _newState;

        emit Whitelist(_proxy, _newState);
    }

    function _isPair(address receiver) private view returns (bool) {
        if (Address.isContract(receiver)) {
            try IUniswapV2Pair(receiver).token1() returns (address) {
                return true;
            } catch {}
        }

        return false;
    }

    // END OF CONTRACT
}
