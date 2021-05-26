import { connect } from 'react-redux';
import { compose, withState, withProps } from 'recompose';

import { getTokenActionsFetching } from '../reducers';
import { fetchSellToken } from '../actions/tokenActions';

import Loader from './Loader';
import SellModal from './SellModal';
import Coin from '../icons/coin.gif';
import Card from 'react-bootstrap/Card';
import Button from 'react-bootstrap/Button';
import ListGroup from 'react-bootstrap/ListGroup';
import ListGroupItem from 'react-bootstrap/ListGroupItem';

import '../styles/TokenPage.scss';

const TokenPage = ({
  token,
  showModal,
  setShowModal,
  fetchSellToken,
  tokenActionFetching,
}) => (
  <div className='TokenPage'>
    <h3 className='heading'>Token view page</h3>
    <div className='card-container'>
      <Card.Img
        src={token.image ? `https://ipfs.io/ipfs/${token.image}` : Coin}
      />
      <Card>
        <Card.Body>
          <Card.Title>{token.name}</Card.Title>
          <Card.Text>{token.description}</Card.Text>
        </Card.Body>

        <Card.Body>
          <ListGroup className='list-group-flush'>
            <ListGroupItem>
              <Card.Subtitle className='mb-2 text-muted'>Author:</Card.Subtitle>
              {token.author || 'No author'}
            </ListGroupItem>
            <ListGroupItem>
              <Card.Subtitle className='mb-2 text-muted'>Seller id:</Card.Subtitle>
              {token.seller || 'No seller'}
            </ListGroupItem>
            <ListGroupItem>
              <Card.Subtitle className='mb-2 text-muted'>Price:</Card.Subtitle>
              {token.price ? `${token.price} ADA` : 'Token is not selling'}
            </ListGroupItem>
          </ListGroup>
        </Card.Body>

        {!token.price && (
          <Card.Body>
            <Button variant='secondary' onClick={() => setShowModal(true)}>
              Sell token
            </Button>
          </Card.Body>
        )}
        
        {token.price && (
          <Card.Body>
            <Button variant='secondary' disabled>Token action</Button>
          </Card.Body>
        )}
      </Card>
    </div>

    <SellModal
      show={showModal}
      setShowModal={setShowModal}
      token={token}
      fetchSellToken={fetchSellToken}
    />

    {tokenActionFetching && (
      <Loader
        disableBackground={true}
        text={'Please, be patient. Token is selling...'}
      />
    )}
  </div>
);

const enhancer = compose(
  withState('showModal', 'setShowModal', false),
  withProps(() => ({
    token: JSON.parse(localStorage.getItem('viewSingleToken')),
  })),
  connect(
    (state) => ({
      tokenActionFetching: getTokenActionsFetching(state),
    }),
    (dispatch, props) => ({
      fetchSellToken: (data) =>
        dispatch(fetchSellToken(props.currentUser, data)),
    })
  )
);

export default enhancer(TokenPage);
