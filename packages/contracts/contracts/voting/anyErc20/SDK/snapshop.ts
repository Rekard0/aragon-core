import {ethers} from 'hardhat';

export async function createBlockSnapshot(snapshop: any, blockNumber: any) {
  const blockHeader = await getBlockHeader(snapshop.provider, blockNumber);
  return await snapshop.createBlockSnapshot(blockHeader);
}

export async function createAccountSnapshot(
  snapshop: any,
  blockNumber: any,
  account: any
) {
  const proof = await getProof(snapshop.provider, blockNumber, account);
  return await snapshop.createAccountSnapshot(
    blockNumber,
    account,
    proof.accountProof
  );
}

export async function sloadFromSnapshot(
  snapshop: any,
  blockNumber: any,
  account: any,
  slot: any
) {
  const proof = await getProof(snapshop.provider, blockNumber, account, [slot]);
  return await snapshop.sloadFromSnapshot(
    blockNumber,
    account,
    fixedField(slot),
    proof.storageProof[0].proof
  );
}

export async function getBlockHeader(provider: any, blockNumber: any) {
  const block = await provider.send('eth_getBlockByNumber', [
    ethers.utils.hexValue(blockNumber),
    false,
  ]);
  return formatBlockHeader(block);
}

export function formatBlockHeader(block: any) {
  return ethers.utils.RLP.encode([
    fixedField(block.parentHash),
    fixedField(block.sha3Uncles),
    fixedField(block.miner, 20),
    fixedField(block.stateRoot),
    fixedField(block.transactionsRoot),
    fixedField(block.receiptsRoot),
    fixedField(block.logsBloom, 256),
    dynamicField(block.difficulty),
    dynamicField(block.number),
    dynamicField(block.gasLimit),
    dynamicField(block.gasUsed),
    dynamicField(block.timestamp),
    dynamicField(block.extraData),
    fixedField(block.mixHash),
    fixedField(block.nonce, 8),
    dynamicField(block.baseFeePerGas),
  ]);
}

export async function getProof(
  provider: any,
  blockNumber: any,
  account: any,
  slots: any = []
) {
  const slotsHex = slots.map(function (slot: any) {
    return fixedString(slot);
  });
  return await provider.send('eth_getProof', [
    account,
    slotsHex,
    ethers.utils.hexValue(blockNumber),
  ]);
}

export function mapSlot(mapSlotRoot: any, key: any) {
  return ethers.utils.keccak256(
    ethers.utils.concat([fixedField(key), fixedField(mapSlotRoot)])
  );
}

export function fixedString(value: any, length = 32) {
  return ethers.utils.hexlify(fixedField(value, length));
}

export function fixedField(value: any, length = 32) {
  return ethers.utils.zeroPad(dynamicField(value), length);
}

export function dynamicField(value: any) {
  return ethers.utils.arrayify(value, {hexPad: 'left'});
}

// exports dummy function for hardhat-deploy. Otherwise we would have to move this file
export default function () {}
