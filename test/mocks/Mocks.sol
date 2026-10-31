// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @notice Тестовые двойки: только для тестов, не часть протокольной сборки.

/// MockUSDC с EIP-3009 receiveWithAuthorization (ERC-3009 семантика:
/// вызывать может только получатель to).
contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    // хэш типа ERC-3009
    bytes32 public constant RECEIVE_WITH_AUTH_TYPE =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes("2")),
            block.chainid,
            address(this)
        ));
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a < amount) revert("insufficient allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert("insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @notice EIP-3009: перевод по подписи; требование ERC-3009 —
    ///          вызывать должен сам получатель (to == msg.sender).
    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        if (msg.sender != to) revert("caller must be the payee");
        if (block.timestamp <= validAfter) revert("authorization not yet valid");
        if (block.timestamp >= validBefore) revert("authorization expired");
        if (authorizationState[from][nonce]) revert("authorization is already used");
        bytes32 digest = keccak256(abi.encodePacked(
            bytes1(0x19), bytes1(0x01),
            DOMAIN_SEPARATOR(),
            keccak256(abi.encode(RECEIVE_WITH_AUTH_TYPE, from, to, value, validAfter, validBefore, nonce))
        ));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != from) revert("invalid signature");
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }
}

/// @notice WETH9-подобная обёртка.
contract MockWETH {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed to, uint256 value);
    event Withdrawal(address indexed from, uint256 value);

    receive() external payable { deposit(); }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        if (balanceOf[msg.sender] < amount) revert("insufficient balance");
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
        emit Withdrawal(msg.sender, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert("insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a < amount) revert("insufficient allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        if (balanceOf[from] < amount) revert("insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/// @notice aToken (1:1 к underlying при индексе 1.0); для эмуляции
///          ребейсинга кампания AT-16 может двигать supplyIndex.
contract MockAToken {
    address public immutable underlying;
    string public name;
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public supplyIndex = 1e27; // ray

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address underlying_) {
        underlying = underlying_;
        name = "MockAToken";
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (balanceOf[from] < amount) revert("insufficient aToken");
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) revert("insufficient aToken");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a < amount) revert("insufficient aToken allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        if (balanceOf[from] < amount) revert("insufficient aToken");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Mock Aave v3 Pool: supply минтит aToken на onBehalfOf 1:1;
///          withdraw сжигает aTokens вызывающего и выплачивает underlying.
contract MockAavePool {
    MockAToken public immutable aUSDC;
    MockAToken public immutable aWETH;
    MockUSDC public immutable usdc;
    MockWETH public immutable weth;

    constructor(address usdc_, address weth_) {
        usdc = MockUSDC(usdc_);
        weth = MockWETH(payable(weth_));
        aUSDC = new MockAToken(address(usdc));
        aWETH = new MockAToken(address(weth));
    }

    function aTokenOf(address asset) external view returns (address) {
        if (asset == address(usdc)) return address(aUSDC);
        if (asset == address(weth)) return address(aWETH);
        revert("unknown asset");
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        if (asset == address(usdc)) {
            usdc.transferFrom(msg.sender, address(this), amount);
            aUSDC.mint(onBehalfOf, amount);
        } else if (asset == address(weth)) {
            weth.transferFrom(msg.sender, address(this), amount);
            aWETH.mint(onBehalfOf, amount);
        } else {
            revert("unknown asset");
        }
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        if (asset == address(usdc)) {
            aUSDC.burn(msg.sender, amount);
            usdc.transfer(to, amount);
        } else if (asset == address(weth)) {
            aWETH.burn(msg.sender, amount);
            weth.transfer(to, amount);
        } else {
            revert("unknown asset");
        }
        return amount;
    }

    function getReserveNormalizedIncome(address) external pure returns (uint256) {
        return 1e27; // ray, индекс 1.0
    }
}

/// @notice Реентрантный получатель (AT-11).
contract ReentrancyAttacker {
    address public target;
    uint256 public attacks;

    function setTarget(address t) external { target = t; }

    receive() external payable {
        attacks++;
        (bool ok, ) = target.call(abi.encodeWithSignature("execute(bytes)", bytes("")));
        ok;
    }
}
