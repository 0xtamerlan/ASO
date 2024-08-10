interface IBlastPoints {
    function configurePointsOperator(address operator) external;
}
IBlast constant BLAST = IBlast(0x4300000000000000000000000000000000000002);

interface IBlast {
    enum GasMode {
        VOID,
        CLAIMABLE
    }
    enum YieldMode {
        AUTOMATIC,
        VOID,
        CLAIMABLE
    }

    // configure
    function configureContract(
        address contractAddress,
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;

    function configure(
        YieldMode _yield,
        GasMode gasMode,
        address governor
    ) external;

    // base configuration options
    function configureClaimableYield() external;

    function configureClaimableYieldOnBehalf(address contractAddress) external;

    function configureAutomaticYield() external;

    function configureAutomaticYieldOnBehalf(address contractAddress) external;

    function configureVoidYield() external;

    function configureVoidYieldOnBehalf(address contractAddress) external;

    function configureClaimableGas() external;

    function configureClaimableGasOnBehalf(address contractAddress) external;

    function configureVoidGas() external;

    function configureVoidGasOnBehalf(address contractAddress) external;

    function configureGovernor(address _governor) external;

    function configureGovernorOnBehalf(
        address _newGovernor,
        address contractAddress
    ) external;

    // claim yield
    function claimYield(
        address contractAddress,
        address recipientOfYield,
        uint256 amount
    ) external returns (uint256);

    function claimAllYield(
        address contractAddress,
        address recipientOfYield
    ) external returns (uint256);

    // claim gas
    function claimAllGas(
        address contractAddress,
        address recipientOfGas
    ) external returns (uint256);

    function claimGasAtMinClaimRate(
        address contractAddress,
        address recipientOfGas,
        uint256 minClaimRateBips
    ) external returns (uint256);

    function claimMaxGas(
        address contractAddress,
        address recipientOfGas
    ) external returns (uint256);

    function claimGas(
        address contractAddress,
        address recipientOfGas,
        uint256 gasToClaim,
        uint256 gasSecondsToConsume
    ) external returns (uint256);

    // read functions
    function readClaimableYield(
        address contractAddress
    ) external view returns (uint256);

    function readYieldConfiguration(
        address contractAddress
    ) external view returns (uint8);

    function readGasParams(
        address contractAddress
    )
        external
        view
        returns (
            uint256 etherSeconds,
            uint256 etherBalance,
            uint256 lastUpdated,
            GasMode
        );
}
IERC20Rebasing constant BLAST_USDB = IERC20Rebasing(
    0x4300000000000000000000000000000000000003
);
IERC20Rebasing constant BLAST_WETH = IERC20Rebasing(
    0x4300000000000000000000000000000000000004
);

interface IERC20Rebasing {
    enum YieldMode {
        AUTOMATIC,
        VOID,
        CLAIMABLE
    }

    function configure(YieldMode) external returns (uint256);

    function price() external view returns (uint256);
}

contract BlastCommon {
    function initializeBlast() internal {
        if (block.chainid == 81457) {
            BLAST.configureAutomaticYield();
            BLAST.configureClaimableGas();
            BLAST_USDB.configure(IERC20Rebasing.YieldMode.AUTOMATIC);
            BLAST_WETH.configure(IERC20Rebasing.YieldMode.AUTOMATIC);
            IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800)
                .configurePointsOperator(
                    0x95b5A949060139fDa5589fB8c2fE23CF2DA30C13
                );
            BLAST.configureGovernor(0x79799832D9288509D2c37a2Ae6B0D742ae5C434D);
        }
    }

    function initializeBlastClaimable() internal {
        if (block.chainid == 81457) {
            BLAST.configureAutomaticYield();
            BLAST.configureClaimableGas();
            BLAST_USDB.configure(IERC20Rebasing.YieldMode.CLAIMABLE);
            BLAST_WETH.configure(IERC20Rebasing.YieldMode.CLAIMABLE);
            IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800)
                .configurePointsOperator(
                    0x95b5A949060139fDa5589fB8c2fE23CF2DA30C13
                );
            BLAST.configureGovernor(0x79799832D9288509D2c37a2Ae6B0D742ae5C434D);
        }
    }
}
