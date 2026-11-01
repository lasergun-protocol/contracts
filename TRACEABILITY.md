# Матрица трассировки: реестр 13.3 → корпус

Статус: **forge 114/114 PASS** (30 сюит), **SDK jest 68/68 PASS** (4 сюиты),
E2E-смоук onchain — зелёный. Прогон: `forge test` (contracts/), `npx jest` (sdk/).

## Адверсариальные тесты AT-1…AT-25

| ID | Содержание (реестр 13.3) | Файл | Тестов | Статус |
|---|---|---|---:|---|
| AT-1 | стат-линковка, порог 1/N, alpha=0.01 | `test/at1_unlinkability.t.sol` | 2 | PASS |
| AT-2 | траты в B+1/B+2/B+100/B+1000 на форках | `test/at2_crossblock.t.sol` | 2 | PASS |
| AT-3 | inventory ABI + байткода, EIP-1967, минт-пути | `test/at3_no_privileges.t.sol` | 4 | PASS |
| AT-4 | InvalidSignature на чужом кольце | `test/at/at4_forge_ring.t.sol` | 1 | PASS |
| AT-5 | подмена recipient/assetId в M | `test/at/at5_m_binding.t.sol` | 3 | PASS |
| AT-6 | NullifierSpent (double spend) | `test/at/at6_double_spend.t.sol` | 1 | PASS |
| AT-7 | RingTooSmall / RingTooLarge | `test/at/at7_ring_bounds.t.sol` | 2 | PASS |
| AT-8 | UnknownCommitment (чужой номинал в кольце) | `test/at/at8_wrong_denom_ring.t.sol` | 2 | PASS |
| AT-9 | InvalidPoint (минт и трата) | `test/at/at9_invalid_points.t.sol` | 8 | PASS |
| AT-10 | rebuild == on-chain state (вкл. конверты) | `test/at/at10_event_rebuild.t.sol` | 1 | PASS |
| AT-11 | реентрант-получатель и приёмник | `test/at/at11_reentrancy.t.sol` | 2 | PASS |
| AT-12 | INV-16 + INV-17 (fuzz, консервация) | `test/at/at12_conservation_invariant.t.sol` | 1 (512 runs) | PASS |
| AT-13 | ack повтора / NullifierSpent (ядро) | `test/at/at13_duplicate_ack.t.sol` | 3 | PASS |
| AT-14 | DuplicateRingMember | `test/at/at14_ring_uniqueness.t.sol` | 2 | PASS |
| AT-15 | DuplicateCommitment | `test/at/at15_duplicate_deposit.t.sol` | 3 | PASS |
| AT-16 | покрытие казны, свип-границы (fuzz) | `test/at/at16_treasury_coverage.t.sol` | 2 | PASS |
| AT-17 | EIP-3009 на другой приёмник/параметры | `test/at/at17_eip3009_binding.t.sol` | 3 | PASS |
| AT-18 | CREATE2-binding, ранний деплой, минт-гейты | `test/at/at18_receiver_binding.t.sol` | 4 | PASS |
| AT-19 | конверты: окна, пермишлес, консервация | `test/at/at19_envelopes.t.sol` | 11 | PASS |
| AT-20 | частичная передача, executor-границы | `test/at/at20_partial_and_executor.t.sol` | 6 | PASS |
| AT-21 | посев: покрытие номиналов, неотличимость | `test/at/at21_seed_profile.t.sol` | 2 | PASS |
| AT-22 | freeze / caps / blacklist-реверт деградаций | `test/at/at22_degradations.t.sol` | 3 | PASS |
| AT-23 | комиссионная консервация, гейты sweepFees | `test/at/at23_fees.t.sol` | 5 | PASS |
| AT-24 | приёмники вывода, стелс-доставка, смена адресата | `test/at/at24_payout_receivers.t.sol` | 3 | PASS |
| AT-25 | no-op повтора executor'а (система) | `test/at/at25_executor_replay.t.sol` | 3 | PASS |

## Сопутствующие сюиты

| Сюита | Файл | Тестов | Статус |
|---|---|---:|---|
| Юнит: Points (парсинг, on-curve, x‖y) | `test/unit/Crypto.t.sol` | 8 | PASS |
| Юнит: LSAG (форматы, векторы) | `test/unit/Crypto.t.sol` | 6 | PASS |
| Юнит: Grid (сетка, разложения, fee) | `test/unit/Grid.t.sol` | 14 | PASS |
| Газ-снапшот (гейт R4) | `test/at/gas_snapshot.t.sol` | 6 | PASS |
| SpendRepro (регрессия реверта spend-цикла) | `test/SpendRepro.t.sol` | 1 | PASS |

Итого forge: **114** тестов в 30 сюитах, 0 failed.

## SDK (TypeScript, реестровые юниты S1)

| Сюита | Файл | Тестов | Статус |
|---|---|---:|---|
| Сетка {1,3,5}×10^k + комиссии 6.7 | `sdk/test/grid_fees.test.ts` | 9 | PASS |
| Кросс-векторы JS↔Solidity (S1) | `sdk/test/lsag_vectors.test.ts` | 5 | PASS |
| Ноты: build/pack/unpack/change/payee | `sdk/test/notes.test.ts` | 7 | PASS |
| Стелс-деривация (6.1, самозалечивание) | `sdk/test/stealth.test.ts` | 3 | PASS |

Итого jest: **68** тестов в 4 сюитах (часть кейсов генерируется параметризованно
внутри сюит — например, полный обход сетки номиналов), 0 failed.

## Среда и допуски

- Precompile 0x07 (`ecMul`) в текущей foundry/revm-среде недоступен: `Points.ecMul`
  использует ограниченный статикколл 0x07 с fallback на двойной 0x06 (g2-подход).
  Газ-факты фиксируются fallback-среды (см. README); прод-гейт — precompile-среда.
- Инвариант-кампания AT-12: 512 рандомизированных прогонов консервации на сид.
