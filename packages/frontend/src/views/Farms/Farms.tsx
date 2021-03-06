import React, { useState } from 'react'
import { Route, Switch, useRouteMatch } from 'react-router-dom'
import { useWallet } from 'use-wallet'

import StrudelIcon from '../../components/StrudelIcon'
import AstroWave from '../../assets/img/astroWave.png'
import ThumbsUp from '../../assets/img/thumbs_up_astronaut.png'

import Button from '../../components/Button'
import Page from '../../components/Page'

import PageHeader from '../../components/PageHeader'
import WalletProviderModal from '../../components/WalletProviderModal'

import useModal from '../../hooks/useModal'

import Farm from '../Farm'
import styled from 'styled-components'
import { withStyles } from '@material-ui/core'

import FarmCards from './components/FarmCards'
import MuiContainer from '@material-ui/core/Container'
import { TerraFarm } from '../../components/Lottie'
import Spacer from '../../components/Spacer'
import MuiPaper from '@material-ui/core/Paper'

const Paper = withStyles({
  rounded: {
    'border-radius': '10px',
  },
  root: {
    margin: 'auto',
    '@media (min-width: 500px)': {
      width: '70%',
    },
    '& > *': {
      padding: '10px',
    },
  },
})(MuiPaper)
const Container = withStyles({
  root: {
    margin: 'auto',
    textAlign: 'center',
  },
})(MuiContainer)

const Farms: React.FC = () => {
  const { path } = useRouteMatch()
  const { account } = useWallet()
  const [onPresentWalletProviderModal] = useModal(<WalletProviderModal />)
  return (
    <Switch>
      <Page>
            {!!account ? (
              <>
                <Route exact path={path}>
                  <PageHeader
                    icon={
                      <StyledMoving>
                        <TerraFarm />
                      </StyledMoving>
                    }
                    iconSize={200}
                    subtitle="Earn $TRDL by staking LP Tokens."
                    title="Terra-Farms to Explore"
                  />
                  <Container maxWidth="md">
                    <StyledP>
                      The Terra-Farms strengthen the protocol and the peg of
                      vBTC to BTC.
                    </StyledP>
                    <StyledP>
                      $TRDL is the crypto-economical incentive to stake and earn
                      rewards by being short on <br /> BTC dominance and long on
                      Ethereum.  
                    </StyledP>
                  </Container>
                  <Spacer size="sm" />
                  <FarmCards />
                  <AstroWrapper>
                    <img src={AstroWave} height="150" />
                  </AstroWrapper>
                </Route>
                <Route path={`${path}/:farmId`}>
                  <Farm />
                </Route>
              </>
            ) : (
              <div
                style={{
                  alignItems: 'center',
                  display: 'flex',
                  flex: 1,
                  justifyContent: 'center',
                }}
              >
                <Button
                  onClick={onPresentWalletProviderModal}
                  text="🔓 Unlock Wallet"
                />
              </div>
            )}

      </Page>
    </Switch>
  )
}
const AstroWrapper = styled.div`
  position: absolute;
  bottom: 20px;
  right: 10vw;
  margin: auto;
  z-index: -90000;
  @media (max-width: 600px) and (orientation: portrait) {
    display: none;
  }
`

const StyledP = styled.p`
  text-align: center;
`

const StyledMulti = styled.span`
  font-size: 35px;
  font-family: 'Falstin', sans-serif;
  font-weight: 700;
`

const StyledMoving = styled.div`
  & > div {
    height: 200px;
  }
`

export default Farms
