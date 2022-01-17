// original file: https://github.com/Synthetixio/Unipool/blob/master/test/Unipool.js

const { BN, time } = require('@openzeppelin/test-helpers');
const { expect } = require('chai');
const { TestHelper } = require('../utils/testHelpers.js');
const testHelpers = require("../utils/testHelpers.js")

const { assertRevert } = TestHelper;

const th = testHelpers.TestHelper
const StakedToken = artifacts.require('ERC20Mock');
const YetiToken = artifacts.require("./YETITokenTester.sol")
const Farm = artifacts.require('Farm');
const NonPayable = artifacts.require('NonPayable');

const _1e18 = new BN('10').pow(new BN('18'));

const almostEqualDiv1e18 = function (expectedOrig, actualOrig) {
  const expected = expectedOrig.div(_1e18);
  const actual = actualOrig.div(_1e18);
  this.assert(
    expected.eq(actual) ||
    expected.addn(1).eq(actual) || expected.addn(2).eq(actual) ||
    actual.addn(1).eq(expected) || actual.addn(2).eq(expected),
    'expected #{act} to be almost equal #{exp}',
    'expected #{act} to be different from #{exp}',
    expectedOrig.toString(),
    actualOrig.toString(),
  );
};

require('chai').use(function (chai, utils) {
  chai.Assertion.overwriteMethod('almostEqualDiv1e18', function (original) {
    return function (value) {
      if (utils.flag(this, 'bignumber')) {
        var expected = new BN(value);
        var actual = new BN(this._obj);
        almostEqualDiv1e18.apply(this, [expected, actual]);
      } else {
        original.apply(this, arguments);
      }
    };
  });
});

contract('Farm Test 2', function ([_, wallet1, wallet2, wallet3, wallet4, bountyAddress, owner]) {
  let multisig = "0x5b5e5CC89636CA2685b4e4f50E66099EBCFAb638"  // Arbitrary address for the multisig, which is not tested in this file

  const deploy = async (that) => {
    that.stakedToken = await StakedToken.new('Staked Token', 'LPT', owner, 0);

    const sYETI = await NonPayable.new();
    const treasury = await NonPayable.new();
    const team = await NonPayable.new();
    that.yeti = await YetiToken.new(
      sYETI.address,
      treasury.address,
      team.address
    );

    that.lpRewardsEntitlement = new BN(await web3.utils.toWei(new BN(10**6 * 4 )));
    that.DURATION = new BN(7 * 24 * 60 * 60); // One week
    that.rewardRate = that.lpRewardsEntitlement.div(that.DURATION);

    that.pool = await Farm.new(that.stakedToken.address, that.yeti.address);

    await that.stakedToken.mint(wallet1, web3.utils.toWei('1000'));
    await that.stakedToken.mint(wallet2, web3.utils.toWei('1000'));
    await that.stakedToken.mint(wallet3, web3.utils.toWei('1000'));
    await that.stakedToken.mint(wallet4, web3.utils.toWei('1000'));

    await that.stakedToken.approve(that.pool.address, new BN(2).pow(new BN(255)), { from: wallet1 });
    await that.stakedToken.approve(that.pool.address, new BN(2).pow(new BN(255)), { from: wallet2 });
    await that.stakedToken.approve(that.pool.address, new BN(2).pow(new BN(255)), { from: wallet3 });
    await that.stakedToken.approve(that.pool.address, new BN(2).pow(new BN(255)), { from: wallet4 });
  };

  describe('Farm', async function () {
    beforeEach(async function () {
      await deploy(this);
    });


    it('Deposit and withdraw immediately gives you 0 rewards', async function () {
      await this.yeti.unprotectedMint(this.pool.address, this.lpRewardsEntitlement)
      await this.pool.notifyRewardAmount(this.lpRewardsEntitlement, this.DURATION);


      expect(await this.pool.rewardPerToken()).to.be.bignumber.almostEqualDiv1e18('0');
      expect(await this.pool.earned(wallet1)).to.be.bignumber.equal('0');
      expect(await this.pool.earned(wallet2)).to.be.bignumber.equal('0');

      const stake1 = new BN(web3.utils.toWei('1'));
      console.log("Wallet 1", wallet1);
      console.log("Wallet 2", wallet2);
      await this.pool.stake(stake1, { from: wallet1 });
      const stakeTime1 = await time.latest();

      await time.increaseTo(stakeTime1.add(this.DURATION));

      const stake2 = new BN(web3.utils.toWei('1'));
      await this.pool.stake(stake2, { from: wallet2 });

      const bal1 = await this.yeti.balanceOf(wallet2);
      assert.equal(bal1, "0")
      await this.pool.getReward({from: wallet2})
      const bal2 = await this.yeti.balanceOf(wallet2);
      assert.equal(bal2, "0")
    });


    it('Rate changes with two stakers. Confirm rewards work fine', async function () {
      await this.yeti.unprotectedMint(this.pool.address, this.lpRewardsEntitlement)
      await this.pool.notifyRewardAmount(this.lpRewardsEntitlement, this.DURATION);

      expect(await this.pool.rewardPerToken()).to.be.bignumber.almostEqualDiv1e18('0');
      expect(await this.pool.earned(wallet1)).to.be.bignumber.equal('0');
      expect(await this.pool.earned(wallet2)).to.be.bignumber.equal('0');

      const stake1 = new BN(web3.utils.toWei('1'));
      console.log("Wallet 1", wallet1);
      console.log("Wallet 2", wallet2);
      await this.pool.stake(stake1, { from: wallet1 });
      const stakeTime1 = await time.latest();

      await time.increaseTo(stakeTime1.add(new BN("86400")));

      const bal1 = await this.yeti.balanceOf(wallet1);
      assert.equal(bal1, "0")
      const timeStaked = (await time.latest()).sub(stakeTime1);
      await this.pool.getReward({from: wallet1})
      const bal2 = await this.yeti.balanceOf(wallet1);
      const expectedReward = this.lpRewardsEntitlement.mul(timeStaked).div(this.DURATION);

      console.log("Bal2", bal2.toString());
      console.log(expectedReward.toString());
      th.assertIsApproximatelyEqual(bal2, expectedReward);

      await this.yeti.unprotectedMint(this.pool.address, 2 * this.lpRewardsEntitlement);

      // const stake2 = new BN(web3.utils.toWei('1'));
      // await this.pool.stake(stake2, { from: wallet2 });
      //
      // const bal1 = await this.yeti.balanceOf(wallet2);
      // assert.equal(bal1, "0")
      // await this.pool.getReward({from: wallet2})
      // const bal2 = await this.yeti.balanceOf(wallet2);
      // assert.equal(bal2, "0")
    });

  });
});
