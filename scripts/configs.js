require('dotenv').config();

module.exports = {
  kovan: {
    dev: process.env.KOVAN_MULTI_DEV,
    gov: process.env.KOVAN_MULTI_GOV,
    treasury: process.env.KOVAN_MULTI_TREASURY,
    auditor: process.env.KOVAN_AUDITOR,
    dai: process.env.KOVAN_DAI,
    coverPool: process.env.KOVAN_COVERPOOL_IMPL,
    cover: process.env.KOVAN_COVER_IMPL,
    coverERC20: process.env.KOVAN_COVERERC20_IMPL,
    factory: process.env.KOVAN_FACTORY,
    claimManagement: process.env.KOVAN_CLAIMMANAGEMENT,
  },  
  mainnet: {
    dev: process.env.MAINNET_MULTI_DEV,
    gov: process.env.MAINNET_MULTI_GOV,
    treasury: process.env.MAINNET_MULTI_TREASURY,
    auditor: process.env.MAINNET_AUDITOR,
    dai: process.env.MAINNET_DAI,
    coverPool: process.env.MAINNET_COVERPOOL_IMPL,
    cover: process.env.MAINNET_COVER_IMPL,
    coverERC20: process.env.MAINNET_COVERERC20_IMPL,
    factory: process.env.MAINNET_FACTORY,
    claimManagement: process.env.MAINNET_CLAIMMANAGEMENT,
  },
}