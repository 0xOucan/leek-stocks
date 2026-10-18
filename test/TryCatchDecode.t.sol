// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// A token whose transfer succeeds but returns nothing, like pre-2020 USDT.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    // Deliberately no return value.
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Router {
    bool public caught;
    bool public moved;

    /// Exactly the shape used in IssuanceVault._routeRevenue.
    function typedTry(address token, address to, uint256 amount) external {
        try IERC20(token).transfer(to, amount) returns (bool ok) {
            moved = ok;
        } catch {
            caught = true;
            moved = false;
        }
    }

    /// The low-level form, which tolerates empty returndata.
    function lowLevel(address token, address to, uint256 amount) external {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        moved = success && (data.length == 0 || abi.decode(data, (bool)));
        caught = !success;
    }
}

contract TryCatchDecodeTest is Test {
    NoReturnToken token;
    Router router;

    function setUp() public {
        token = new NoReturnToken();
        router = new Router();
        token.mint(address(router), 100);
    }

    function test_aTypedTryIsNotCaughtWhenTheCalleeReturnsNothing() public {
        // The claim: Solidity decodes a SUCCESSFUL call's return data outside
        // the catch frame, so a decode failure propagates and the catch never
        // runs. If that is true this reverts rather than setting `caught`.
        vm.expectRevert();
        router.typedTry(address(token), address(1), 1);
    }

    function test_theLowLevelFormHandlesIt() public {
        router.lowLevel(address(token), address(1), 1);
        assertTrue(router.moved(), "the transfer was not recognised as moved");
        assertFalse(router.caught());
        assertEq(token.balanceOf(address(1)), 1);
    }
}
