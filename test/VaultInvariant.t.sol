// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vault} from "../src/Vault.sol";
import {FeeSource} from "../src/libraries/FeeSource.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Sink {
    receive() external payable {}
}

contract VaultHandler is Test {
    Vault public immutable vault;
    MockERC20 public immutable token;
    address public immutable sink;

    uint256 public ghost_nativeIn;
    uint256 public ghost_nativeOut;
    uint256 public ghost_tokenIn;
    uint256 public ghost_tokenOut;
    uint256 public ghost_feeWithdrawn;

    constructor(Vault _v, MockERC20 _t, address _sink) {
        vault = _v;
        token = _t;
        sink = _sink;
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(_v), type(uint256).max);
    }

    receive() external payable {}

    function depositDual(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(address(this), address(this).balance + amount);
        try vault.depositDual{value: amount}(keccak256("org")) {
            ghost_nativeIn += amount;
        } catch {}
    }

    function depositFloat(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.deal(address(this), address(this).balance + amount);
        try vault.depositFloat{value: amount}() {
            ghost_nativeIn += amount;
        } catch {}
    }

    function depositToken(uint256 amount) public {
        amount = bound(amount, 1, token.balanceOf(address(this)));
        if (amount == 0) return;
        try vault.deposit(address(token), keccak256("org"), amount) {
            ghost_tokenIn += amount;
        } catch {}
    }

    function withdrawFee(uint256 amount, bool batch) public {
        uint256 bal = address(vault).balance;
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        uint8 src = batch ? FeeSource.BATCH : FeeSource.LEDGER;
        try vault.withdrawForFeeDistribution(amount, src) {
            ghost_feeWithdrawn += amount;
            ghost_nativeOut += amount; // sent to msg.sender (this handler)
        } catch {}
    }

    function withdrawDual(uint256 amount) public {
        uint256 bal = address(vault).balance;
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try vault.withdrawDual(sink, amount) {
            ghost_nativeOut += amount;
        } catch {}
    }

    function withdrawToken(uint256 amount) public {
        uint256 bal = token.balanceOf(address(vault));
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try vault.withdraw(address(token), sink, amount) {
            ghost_tokenOut += amount;
        } catch {}
    }

    function pauseToggle() public {
        if (vault.paused()) {
            vault.unpause();
        } else {
            vault.pause();
        }
    }
}

contract VaultInvariantTest is Test {
    Vault internal vault;
    VaultHandler internal handler;
    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20();
        Sink sink = new Sink();

        Vault impl = new Vault();
        handler = VaultHandler(payable(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        vault = Vault(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(Vault.initialize, (address(handler)))))));
        VaultHandler deployed = new VaultHandler(vault, token, address(sink));
        require(address(deployed) == address(handler), "handler addr mismatch");

        // Handler is owner; wire it as the fee dispatcher and float depositor too.
        vm.startPrank(address(handler));
        vault.setFeeDispatcher(address(handler));
        vault.grantFloatDepositorRole(address(handler));
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @notice Native conservation: vault balance equals deposits minus all exits
    ///         (fee withdrawals + owner withdrawals).
    function invariant_nativeConserved() public view {
        assertEq(address(vault).balance, handler.ghost_nativeIn() - handler.ghost_nativeOut(), "native not conserved");
    }

    /// @notice ERC20 conservation: the vault's token balance equals deposits minus
    ///         owner withdrawals.
    function invariant_tokenConserved() public view {
        assertEq(
            token.balanceOf(address(vault)), handler.ghost_tokenIn() - handler.ghost_tokenOut(), "token not conserved"
        );
    }

    /// @notice The fee-withdrawal counter exactly tracks fee outflows.
    function invariant_feeCounterAccurate() public view {
        assertEq(vault.totalWithdrawnForFees(), handler.ghost_feeWithdrawn(), "fee counter drift");
    }

    /// @notice A fee withdrawal never exceeds what the vault ever held.
    function invariant_feeWithdrawnBacked() public view {
        assertLe(vault.totalWithdrawnForFees(), handler.ghost_nativeIn(), "fees exceed deposits");
    }
}
