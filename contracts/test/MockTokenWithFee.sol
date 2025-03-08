// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockTokenWithFee
 * @dev Mock ERC20 token that applies a fee on transfer, used for testing slippage protection
 */
contract MockTokenWithFee is ERC20, Ownable {
    uint256 public transferFee; // Fee in basis points (1/100 of a percent)
    
    /**
     * @dev Constructor
     * @param name Token name
     * @param symbol Token symbol
     * @param _transferFee Fee in basis points (1 = 0.01%, 100 = 1%)
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 _transferFee
    ) ERC20(name, symbol) Ownable(msg.sender) {
        transferFee = _transferFee;
    }
    
    /**
     * @dev Mint tokens
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    /**
     * @dev Override ERC20 transfer to apply fee
     * @param to Recipient address
     * @param value Amount to transfer
     * @return success True if transfer successful
     */
    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 fee = value * transferFee / 10000;
        // Unused variable commented out
        // uint256 amountAfterFee = value - fee;
        
        super.transfer(to, value - fee);
        if (fee > 0) {
            // Burn the fee (or could send to a fee collector)
            _burn(_msgSender(), fee);
        }
        
        return true;
    }
    
    /**
     * @dev Override ERC20 transferFrom to apply fee
     * @param from Sender address
     * @param to Recipient address
     * @param value Amount to transfer
     * @return success True if transfer successful
     */
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 fee = value * transferFee / 10000;
        // Unused variable commented out
        // uint256 amountAfterFee = value - fee;
        
        super.transferFrom(from, to, value);
        if (fee > 0) {
            // Burn the fee
            _burn(to, fee);
        }
        
        return true;
    }
    
    /**
     * @dev Set transfer fee
     * @param _transferFee New fee in basis points
     */
    function setTransferFee(uint256 _transferFee) external onlyOwner {
        transferFee = _transferFee;
    }
} 