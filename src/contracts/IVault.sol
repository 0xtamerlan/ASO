interface ConstantProductPoolFactory {
    function deploy(
        bytes32 quoteToken,
        bytes32 baseToken
    ) external returns (address);

    function pools(bytes32, bytes32) external view returns (address);
}

interface IVault {
    function execute1(
        address pool,
        uint8 method,
        address t1,
        uint8 m1,
        int128 a1,
        bytes memory data
    ) external payable returns (int128[] memory);

    function query1(
        address pool,
        uint8 method,
        address t1,
        uint8 m1,
        int128 a1,
        bytes memory data
    ) external returns (int128[] memory);

    function execute2(
        address pool,
        uint8 method,
        address t1,
        uint8 m1,
        int128 a1,
        address t2,
        uint8 m2,
        int128 a2,
        bytes memory data
    ) external payable returns (int128[] memory);

    function query2(
        address pool,
        uint8 method,
        address t1,
        uint8 m1,
        int128 a1,
        address t2,
        uint8 m2,
        int128 a2,
        bytes memory data
    ) external returns (int128[] memory);

    function execute3(
        address pool,
        uint8 method,
        address t1,
        uint8 m1,
        int128 a1,
        address t2,
        uint8 m2,
        int128 a2,
        address t3,
        uint8 m3,
        int128 a3,
        bytes memory data
    ) external payable returns (int128[] memory);
}
