pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

// 本合约为一个正常的带有permit授权的ERC20合约
contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    // name和symbol分别为常量'Uniswap V2'和'UNI-V2'
    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    // 精度
    uint8 public constant decimals = 18;
    // 总发行量
    uint  public totalSupply;
    // 用于记录每个holder余额的mapping
    mapping(address => uint) public balanceOf;
    // 用于记录授权信息的mapping
    mapping(address => mapping(address => uint)) public allowance;

    // EIP712中的domain separator
    bytes32 public DOMAIN_SEPARATOR;

    // permit授权中结构化数据Permit的type hash（固定不变）
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // 每个地址进行permit授权使用的nonce值（防止permit交易的签名被重用）
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            // 获取当前链的chain-id
            chainId := chainid
        }

        // 设置本合约的DOMAIN_SEPARATOR，用于permit授权（基于EIP712）
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                // 签名域EIP712Domain的type hash(固定不变)
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                // name hash
                keccak256(bytes(name)),
                // version hash. 注：version为'1'
                keccak256(bytes('1')),
                // 当前chainid
                chainId,
                // 本合约地址
                address(this)
            )
        );
    }

    // 给to地址增发数量为value的pair token
    function _mint(address to, uint value) internal {
        // 增加value到总发行量
        totalSupply = totalSupply.add(value);
        // to地址的余额增加value
        balanceOf[to] = balanceOf[to].add(value);
        // 抛出事件
        emit Transfer(address(0), to, value);
    }

    // 为from地址销毁数量为value的pair token
    function _burn(address from, uint value) internal {
        // from地址的余额减少value
        balanceOf[from] = balanceOf[from].sub(value);
        // 总发行量减少value
        totalSupply = totalSupply.sub(value);
        // 抛出事件
        emit Transfer(from, address(0), value);
    }

    // 为owner地址授权给spender地址数量为value的pair token
    function _approve(address owner, address spender, uint value) private {
        // 直接修改allowance[owner][spender]的值为value
        allowance[owner][spender] = value;
        // 抛出事件
        emit Approval(owner, spender, value);
    }

    // 从from地址转移给to地址数量为value的pair token
    function _transfer(address from, address to, uint value) private {
        // from地址的余额减少value
        balanceOf[from] = balanceOf[from].sub(value);
        // to地址的余额增加value
        balanceOf[to] = balanceOf[to].add(value);
        // 抛出事件
        emit Transfer(from, to, value);
    }

    // msg.sender向spender地址授权数量为value的pair token
    function approve(address spender, uint value) external returns (bool) {
        // 调用_approve()进行授权操作
        _approve(msg.sender, spender, value);
        // 返回true
        return true;
    }

    // msg.sender向to地址转移数量为value的pair token
    function transfer(address to, uint value) external returns (bool) {
        // 调用_transfer()进行转移pair token操作
        _transfer(msg.sender, to, value);
        // 返回true
        return true;
    }

    // 获得授权额度的spender地址从from地址转移数量为value的token pair到to地址（msg.sender为spender，拥有授权额度）
    function transferFrom(address from, address to, uint value) external returns (bool) {
        // 注：给spender的授权额度设置为type(uint).max，默认该spender可以没有上限地转移owner的余额
        // 即：在每次transferFrom中不记录授权额度的变更
        if (allowance[from][msg.sender] != uint(-1)) {
            // 如果msg.sender来自from的授权额度不是type(uint).max，会在当前授权额度减去value
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        // 调用_transfer()进行转账
        _transfer(from, to, value);
        return true;
    }

    // permit授权
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        // 验证当前时间戳小于参数deadline，否则说明对应传入的签名已过期
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        // 计算签名的digest，即整个基于EIP712的message
        bytes32 digest = keccak256(
            abi.encodePacked(
                // 结构化数据取hash的固定前缀
                '\x19\x01',
                // 用于验证签名的合约的domain separator
                DOMAIN_SEPARATOR,
                // 结构化数据Permit的struct hash
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );

        // 验签
        address recoveredAddress = ecrecover(digest, v, r, s);
        // 要求还原出的签名地址不为0且签名地址为owner
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        // 调用_approve()对spender进行owner的授权操作
        _approve(owner, spender, value);
    }
}
