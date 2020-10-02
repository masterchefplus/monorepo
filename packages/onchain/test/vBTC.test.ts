import {ethers} from "@nomiclabs/buidler";
import {Signer} from "ethers";
import chai from "chai";
import {solidity} from "ethereum-waffle";
import constants from './onDemandSpvHelpers.json';
import failed from './failedTx.json';
import { VBTCToken } from '../typechain/VBTCToken';
import { VBTCTokenFactory } from '../typechain/VBTCTokenFactory';
import { StrudelToken } from '../typechain/StrudelToken';
import { StrudelTokenFactory } from '../typechain/StrudelTokenFactory';
import { MockRelay } from '../typechain/MockRelay';
import { MockRelayFactory } from '../typechain/MockRelayFactory';

chai.use(solidity);
const {expect} = chai;

const BYTES32_0 = '0x0000000000000000000000000000000000000000000000000000000000000000';

async function deploy(signer: Signer, relay: MockRelay): Promise<VBTCToken> {
  let strudelFactory = new StrudelTokenFactory(signer);
  let strudel = await strudelFactory.deploy();
  let factory = new VBTCTokenFactory(signer);
  let vbtc = await factory.deploy(relay.address, strudel.address, 0, relay.address, 50);
  await strudel.addMinter(vbtc.address);
  return vbtc;
}

describe('VBTC', async () => {
  let signers: Signer[];
  let instance: VBTCToken;
  let relay: MockRelay;

  before(async () => {
    signers = await ethers.signers();
    let relayFactory = new MockRelayFactory(signers[0]);
    relay = await relayFactory.deploy(BYTES32_0, 210, BYTES32_0, 211);
  });

  beforeEach(async () => {
    instance = await deploy(signers[0], relay);
  });

  describe('#provideProof', async () => {

    it('happy case', async () => {
      await relay.addHeader(constants.OP_RETURN_BLOCK_HASH, 200);
      const tx = await instance.proofOpReturnAndMint(
        constants.OP_RETURN_HEADER,
        constants.OP_RETURN_PROOF,
        constants.OP_RETURN_VERSION,
        constants.OP_RETURN_LOCKTIME,
        constants.OP_RETURN_INDEX,
        0, // burn output index in transaction
        constants.OP_RETURN_VIN,
        constants.OP_RETURN_VOUT
      );
      const rsp = (await tx.wait(1));
      //console.log(rsp);
      // console.log(rsp.gasUsed?.toNumber());
      // expecting about 256000 gas
    });


    it('failed case', async () => {
      await relay.addHeader(failed.OP_RETURN_BLOCK_HASH, 200);
      const tx = await instance.proofOpReturnAndMint(
        failed.OP_RETURN_HEADER,
        failed.OP_RETURN_PROOF,
        failed.OP_RETURN_VERSION,
        failed.OP_RETURN_LOCKTIME,
        failed.OP_RETURN_INDEX,
        0, // burn output index in transaction
        failed.OP_RETURN_VIN,
        failed.OP_RETURN_VOUT
      );
      const rsp = (await tx.wait(1));
      //console.log(rsp);
      // console.log(rsp.gasUsed?.toNumber());
      // expecting about 256000 gas
    });

  });

});