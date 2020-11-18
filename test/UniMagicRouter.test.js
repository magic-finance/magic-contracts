const UniMagicRouter = artifacts.require("MAGICv1Router");
const UniV2Factory = artifacts.require("UniswapV2Factory");
const WETH = artifacts.require("WETH9");
const MAGIC = artifacts.require("MAGIC");
const MAGICVAULT = artifacts.require("MagicVault");

const UniV2Pair = artifacts.require("UniswapV2Pair");
const FeeApprover = artifacts.require('FeeApprover');

const MerlinFactory = artifacts.require('MerlinFactory');
const MERLIN = artifacts.require('MERLIN');

const truffleAssert = require("truffle-assertions");
const assert = require("chai").assert;

contract("UniMagicRouter", accounts => {

    let testAccount = accounts[0];
    let setterAccount = accounts[1];
    let testAccount2 = accounts[2];

    beforeEach(async () => {
        this.uniV2Factory = await UniV2Factory.new(setterAccount);
        this.weth = await WETH.new();
        this.weth.deposit({ from: setterAccount, value: 10e18.toString() });

        this.magicToken = await MAGIC.new(this.uniV2Factory.address, this.uniV2Factory.address, { from: setterAccount });
        this.feeapprover = await FeeApprover.new({ from: setterAccount });
        this.magicPair = await UniV2Pair.at((await this.uniV2Factory.createPair(this.weth.address, this.magicToken.address)).receipt.logs[0].args.pair);
        await this.feeapprover.initialize(this.magicToken.address, this.weth.address, this.magicPair.address, { from: setterAccount });
        this.magicvault = await MAGICVAULT.new({ from: setterAccount });

        await this.feeapprover.setPaused(false, { from: setterAccount });
        await this.magicToken.setShouldTransferChecker(this.feeapprover.address, { from: setterAccount });


        await this.weth.transfer(this.magicPair.address, 10e18.toString(), { from: setterAccount });
        await this.magicToken.transfer(this.magicPair.address, 10e18.toString(), { from: setterAccount });
        await this.magicPair.mint(setterAccount);

        this.magicRouter = await UniMagicRouter.new(this.magicToken.address, this.weth.address, this.uniV2Factory.address, this.magicPair.address, this.feeapprover.address, this.magicvault.address);

        this.merlinFactory = await MerlinFactory.new();
        await this.merlinFactory.bondContract(this.magicRouter.address);
        await this.magicRouter.setMerlinFactory(this.merlinFactory.address);
    });

    it("should load the context", () => { });

    it("should be able to add liquidity with only eth", async () => {
        truffleAssert.passes(
            await this.magicRouter.addLiquidityETHOnly(testAccount, false, { from: testAccount, value: 10e18.toString() })
        );

        console.log("----Start smaller deposit");
        truffleAssert.passes(
            await this.magicRouter.addLiquidityETHOnly(testAccount, false, { from: testAccount, value: (40000000000000000).toString() })
        );


        truffleAssert.passes(
            await this.magicRouter.addLiquidityETHOnly(testAccount, false, { from: testAccount, value: (99).toString() })
        );

        await this.magicRouter.send(99, { from: testAccount2, value: 99 });

        assert.isTrue((await this.magicPair.balanceOf(testAccount2)).gt(0));

        assert.isTrue((await this.magicPair.balanceOf(testAccount)).gt(0));

        let merlinInstance = await MERLIN.at(await this.magicRouter.getMerlin());
        assert.isTrue((await merlinInstance.balanceOf(testAccount)).gt(0));
    });

});
