require 'test_helper'

class RemoteMitTest < Test::Unit::TestCase
  def setup
    @gateway = MitGateway.new(fixtures(:mit))

    @amount = 291165
    @amount_fail = 29001165

    @credit_card = ActiveMerchant::Billing::CreditCard.new(
      number: '4242424242424242',
      verification_value: '188',
      month: '01',
      year: '2024',
      first_name: 'Mario F.',
      last_name: 'Moreno Reyes'
    )

    @declined_card = ActiveMerchant::Billing::CreditCard.new(
      number: '4242424242424242',
      verification_value: '183',
      month: '01',
      year: '2019',
      first_name: 'Mario F.',
      last_name: 'Moreno Reyes'
    )

    @options_success = {
      order_id: '721',
      transaccion_id: '721', # unique id for every transaction, needs to be generated for every test
      billing_address: address,
      description: 'Store Purchase'
    }

    @options = {
      order_id: '721',
      transaccion_id: '721', # unique id for every transaction, needs to be generated for every test
      billing_address: address,
      description: 'Store Purchase'
    }
  end

  def test_successful_purchase
    # ###############################################################
    # create unique id based on timestamp for testing purposes
    # Each order / transaction passed to the gateway must be unique
    time = Time.now.to_i.to_s
    @options_success[:order_id] = 'TID|' + time
    @options_success[:transaccion_id] = 'TID|' + time
    # ###############################################################
    response = @gateway.purchase(@amount, @credit_card, @options_success)
    assert_success response
    assert_equal ' -0C- ', response.message
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount_fail, @declined_card, @options)
    assert_failure response
    assert_not_equal ' -0C- ', response.message
  end

  def test_successful_authorize_and_capture
    # ###############################################################
    # create unique id based on timestamp for testing purposes
    # Each order / transaction passed to the gateway must be unique
    time = Time.now.to_i.to_s
    @options_success[:order_id] = 'TID|' + time
    @options_success[:transaccion_id] = 'TID|' + time
    # ###############################################################
    auth = @gateway.authorize(@amount, @credit_card, @options_success)
    assert_success auth

    assert capture = @gateway.capture(@amount, auth.authorization, @options_success)
    assert_success capture
    assert_equal ' -0C- ', capture.message
  end

  def test_failed_authorize
    response = @gateway.authorize(@amount_fail, @declined_card, @options)
    assert_failure response
    assert_not_equal ' -0C- ', response.message
  end

  def test_failed_capture
    response = @gateway.capture(@amount_fail, 'requiredauth', @options)
    assert_failure response
    assert_not_equal ' -0C- ', response.message
  end

  def test_successful_refund
    # ###############################################################
    # create unique id based on timestamp for testing purposes
    # Each order / transaction passed to the gateway must be unique
    time = Time.now.to_i.to_s
    @options_success[:order_id] = 'TID|' + time
    @options_success[:transaccion_id] = 'TID|' + time
    # ###############################################################
    purchase = @gateway.purchase(@amount, @credit_card, @options_success)
    assert_success purchase

    # authorization is required
    assert refund = @gateway.refund(@amount, purchase.authorization, @options_success)
    assert_success refund
    assert_equal ' -0C- ', refund.message
  end

  def test_failed_refund
    # authorization is required
    response = @gateway.refund(@amount, 'invalidauth', @options)
    assert_failure response
    assert_not_equal ' -0C- ', response.message
  end
end
