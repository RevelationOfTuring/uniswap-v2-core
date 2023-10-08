pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    // 表示平台手续费收取的地址
    address public feeTo;
    // 可设置feeTo的管理员地址
    address public feeToSetter;

    // 用于记录交易对pair的mapping
    // tokenA和tokenB组成的交易对，可以通过getPair[tokenA][tokenB]或getPair[tokenB][tokenA]查询到pair合约地址
    mapping(address => mapping(address => address)) public getPair;
    // 用于存储所有创建的pair的数组
    address[] public allPairs;
    // 创建pair时抛出
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        // deployer为feeToSetter
        feeToSetter = _feeToSetter;
    }

    // 当前已创建pair的个数
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // 要求tokenA和tokenB不能相等
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // tokenA和tokenB地址中较小的为token0，较大的为token1（即输入参数tokenA和tokenB进行排序）
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 确保该交易对未被创建过
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // 部署UniswapV2Pair合约
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // create2部署合约的salt值为token0.token1的哈希值
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            // 在汇编中使用create2指令（利用salt和合约bytecode）部署UniswapV2Pair合约
            // pair为部署的合约地址
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 调用新部署UniswapV2Pair合约的initialize方法进行初始化
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 在getPair中双向记录pair地址对交易对token0-token1的映射关系
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 向动态数组中追加pair地址
        allPairs.push(pair);
        // 抛出事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 当前feeToSetter设置新的feeTo
    function setFeeTo(address _feeTo) external {
        // 当前feeToSetter身份验证
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        // 设置新的feeTo
        feeTo = _feeTo;
    }

    // 当前feeToSetter设置新的feeToSetter
    function setFeeToSetter(address _feeToSetter) external {
        // 当前feeToSetter身份验证
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        // 设置新的feeToSetter
        feeToSetter = _feeToSetter;
    }
}
