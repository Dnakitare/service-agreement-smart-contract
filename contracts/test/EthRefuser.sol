// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IServiceAgreementWithdraw {
    function withdraw(address token) external returns (uint256);
}

/// @notice Test helper that refuses ETH transfers, used to verify that the pull-payment
/// design isolates a single bad recipient from the rest.
contract EthRefuser {
    function tryWithdraw(address service) external {
        IServiceAgreementWithdraw(service).withdraw(address(0));
    }

    receive() external payable {
        revert("no eth");
    }
}
