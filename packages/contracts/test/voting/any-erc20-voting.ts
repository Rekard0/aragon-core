import {expect} from 'chai';
import {ethers, waffle} from 'hardhat';
import {SignerWithAddress} from '@nomiclabs/hardhat-ethers/signers';

import {DAOMock, AnyERC20Voting, TestERC20} from '../../typechain';
import {
  getBlockHeader,
  getProof,
} from '../../contracts/voting/anyErc20/SDK/snapshop';

describe('AnyERC20Voting', function () {
  let signers: SignerWithAddress[];
  let erc20Token: TestERC20;
  let voting: AnyERC20Voting;
  let daoMock: DAOMock;
  let ownerAddress: string;
  let dummyActions: any;

  before(async () => {
    signers = await ethers.getSigners();
    ownerAddress = await signers[0].getAddress();

    dummyActions = [
      {
        to: ownerAddress,
        data: '0x00000000',
        value: 0,
      },
    ];

    const DAOMock = await ethers.getContractFactory('DAOMock');
    daoMock = await DAOMock.deploy(ownerAddress);

    const ERC20TokenContract = await ethers.getContractFactory('TestERC20');
    erc20Token = await ERC20TokenContract.deploy('Erc20Token', 'ET', 100);
  });

  beforeEach(async () => {
    const ERC20Voting = await ethers.getContractFactory('AnyERC20Voting');
    voting = await ERC20Voting.deploy();

    await voting.initialize(
      daoMock.address,
      ethers.constants.AddressZero,
      1,
      2,
      3,
      erc20Token.address
    );
  });

  it('create a proposal', async () => {
    const blockNumber = await voting.provider.getBlockNumber();
    const blockHeader = await getBlockHeader(voting.provider, blockNumber);
    console.log('=== header ===', blockHeader);
    const proof = await getProof(
      voting.provider,
      blockNumber,
      erc20Token.address
    );
    console.log('=== proof ===', proof);
    await voting.createProposal(
      '0x00',
      dummyActions,
      blockHeader,
      0,
      0,
      proof.accountProof
    );
  });
});
