const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const TREASURY = "0x1BD0Ce03dDC4c90e840513861860Fa1eA481FDB0";
const SEALED = "ipfs://sealed/sealed.json";
const MNEMONIC =
  "test test test test test test test test test test test junk";

async function deployAll() {
  const [owner, alice, bob] = await ethers.getSigners();
  const Mock = await ethers.getContractFactory("MockAgentID");
  const mock = await Mock.deploy();
  const CA = await ethers.getContractFactory("CoffeeAgents");
  const ca = await CA.deploy(await mock.getAddress(), TREASURY, SEALED);
  return { owner, alice, bob, mock, ca };
}

describe("CoffeeAgents — phases & rules", function () {
  it("identity: name, symbol, supply constants", async function () {
    const { ca } = await deployAll();
    expect(await ca.name()).to.equal("Coffee Agents");
    expect(await ca.symbol()).to.equal("BEANS");
    expect(await ca.MAX_SUPPLY()).to.equal(5555);
    expect(await ca.FREE_QUOTA()).to.equal(1500);
    expect(await ca.MAX_PER_WALLET()).to.equal(20);
  });

  it("free mint: needs open mint + Agent ID; 1 per wallet", async function () {
    const { alice, bob, mock, ca } = await deployAll();
    await mock.give(alice.address);
    await expect(ca.connect(alice).mintFree()).to.be.revertedWith(
      "mint not open"
    );
    await ca.startMint();
    await ca.connect(alice).mintFree();
    expect(await ca.ownerOf(1)).to.equal(alice.address);
    await expect(ca.connect(alice).mintFree()).to.be.revertedWith(
      "free already claimed"
    );
    await expect(ca.connect(bob).mintFree()).to.be.revertedWith("no Agent ID");
  });

  it("paid mint is blocked while the free phase runs", async function () {
    const { alice, mock, ca } = await deployAll();
    await mock.give(alice.address);
    await ca.startMint();
    await expect(
      ca.connect(alice).mint(1, { value: ethers.parseEther("0.0005") })
    ).to.be.revertedWith("free phase still running");
  });

  it("final URI: one-shot commit, only before mint starts", async function () {
    const { ca } = await deployAll();
    await ca.commitFinalBaseURI("ipfs://final/");
    await expect(ca.commitFinalBaseURI("ipfs://other/")).to.be.revertedWith(
      "already committed"
    );
    const { ca: ca2 } = await deployAll();
    await ca2.startMint();
    await expect(ca2.commitFinalBaseURI("ipfs://late/")).to.be.revertedWith(
      "mint already started"
    );
  });

  it("withdraw is locked until reveal", async function () {
    const { ca } = await deployAll();
    await expect(ca.withdraw()).to.be.revertedWith("locked until reveal");
  });

  it("sealed URI before reveal", async function () {
    const { alice, mock, ca } = await deployAll();
    await mock.give(alice.address);
    await ca.startMint();
    await ca.connect(alice).mintFree();
    expect(await ca.tokenURI(1)).to.equal(SEALED);
  });

  it("royalty: ERC-2981 default 3% to treasury", async function () {
    const { ca } = await deployAll();
    const [receiver, amount] = await ca.royaltyInfo(
      1,
      ethers.parseEther("1")
    );
    expect(receiver).to.equal(TREASURY);
    expect(amount).to.equal(ethers.parseEther("0.03"));
  });

  it("quotePrice walks the ladder and straddles tiers", async function () {
    const { ca } = await deployAll();
    expect(await ca.quotePrice(1500, 1)).to.equal(ethers.parseEther("0.0005"));
    expect(await ca.quotePrice(2999, 2)).to.equal(ethers.parseEther("0.0015"));
    expect(await ca.quotePrice(3000, 1)).to.equal(ethers.parseEther("0.001"));
    expect(await ca.quotePrice(4499, 2)).to.equal(ethers.parseEther("0.003"));
    expect(await ca.quotePrice(4500, 1)).to.equal(ethers.parseEther("0.002"));
    // full paid range total = 4.36 BNB
    expect(await ca.quotePrice(1500, 4055)).to.equal(ethers.parseEther("4.36"));
  });
});

describe("CoffeeAgents — full free quota, paid phase, finalize, reveal", function () {
  it("runs the whole lifecycle", async function () {
    const { owner, mock, ca } = await deployAll();
    await ca.commitFinalBaseURI("ipfs://final/");
    await ca.startMint();

    // Fill the 1,500 free quota with 1,500 distinct Agent ID wallets.
    const mnemonic = ethers.Mnemonic.fromPhrase(MNEMONIC);
    const root = ethers.HDNodeWallet.fromSeed(mnemonic.computeSeed());
    for (let i = 0; i < 1500; i++) {
      const w = root.derivePath(`m/44'/60'/0'/0/${i}`).connect(ethers.provider);
      await mock.give(w.address);
      await owner.sendTransaction({
        to: w.address,
        value: ethers.parseEther("0.002"),
      });
      await ca.connect(w).mintFree();
    }
    expect(await ca.totalMinted()).to.equal(1500);

    // Paid phase: exact payment only. Buyer is a fresh random wallet —
    // the Hardhat signer accounts overlap the HD free-mint wallets above.
    const buyer = ethers.Wallet.createRandom().connect(ethers.provider);
    await owner.sendTransaction({
      to: buyer.address,
      value: ethers.parseEther("0.1"),
    });
    await expect(
      ca.connect(buyer).mint(1, { value: ethers.parseEther("0.0004") })
    ).to.be.revertedWith("exact payment required");
    await ca.connect(buyer).mint(1, { value: ethers.parseEther("0.0005") });
    expect(await ca.ownerOf(1501)).to.equal(buyer.address);
    expect(await ca.currentPrice()).to.equal(ethers.parseEther("0.0005"));

    // Wallet cap: buyer can reach 20 total, the 21st reverts.
    await ca
      .connect(buyer)
      .mint(19, { value: ethers.parseEther("0.0005") * 19n });
    await expect(
      ca.connect(buyer).mint(1, { value: ethers.parseEther("0.0005") })
    ).to.be.revertedWith("wallet cap");

    // Proceeds stay locked until reveal — even the owner cannot touch them.
    await expect(ca.withdraw()).to.be.revertedWith("locked until reveal");

    // Finalize closes minting forever; reveal only after 48h, by anyone.
    await ca.finalize();
    await expect(
      ca.connect(buyer).mint(1, { value: ethers.parseEther("0.0005") })
    ).to.be.revertedWith("mint not open");
    await expect(ca.connect(buyer).reveal()).to.be.revertedWith(
      "reveal too early"
    );
    await time.increase(48 * 3600 + 1);
    await ca.connect(buyer).reveal(); // permissionless: a holder triggers it
    expect(await ca.tokenURI(1)).to.equal("ipfs://final/1.json");
    await expect(ca.commitFinalBaseURI("ipfs://other/")).to.be.revertedWith(
      "mint already started"
    );

    // After reveal the proceeds unlock to the treasury.
    const before = await ethers.provider.getBalance(TREASURY);
    await ca.withdraw();
    const after = await ethers.provider.getBalance(TREASURY);
    expect(after - before).to.equal(ethers.parseEther("0.0005") * 20n);
  });
});
