require 'json'
require 'openssl'
require 'digest'
require 'base64'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class MitGateway < Gateway
      self.test_url = 'https://dev6.mitec.com.mx/ModuloUtilWS/activeCDP.htm'
      self.live_url = 'https://wpy.mitec.com.mx/ModuloUtilWS/activeCDP.htm'

      self.supported_countries = ['MX']
      self.default_currency = 'MXN'

      self.supported_cardtypes = %i[visa master]

      self.homepage_url = 'http://www.centrodepagos.com.mx/'
      self.display_name = 'MIT Centro de pagos'

      self.money_format = :dollars

      STANDARD_ERROR_CODE_MAPPING = {}

      def initialize(options = {})
        requires!(options, :id_comercio, :user, :apikey, :key_session)
        super
      end

      def purchase(money, payment, options = {})
        authorization = authorize(money, payment, options)
        return authorization unless authorization.success?

        capture(money, payment, options)
      end

      def cipher
        OpenSSL::Cipher::Cipher.new('aes-256-cbc') # ('aes-256-cbc')
      end

      def cipher_key
        self.options[:key_session]
      end

      def decrypt(val, keyinhex)
        # Splits the first 16 bytes (the IV bytes) in array format
        unpacked = val.unpack('m')
        iv_base64 = unpacked[0].bytes.slice(0, 16)
        # Splits the second bytes (the encrypted text bytes) these would be the
        # original message
        full_data = unpacked[0].bytes.slice(16, unpacked[0].bytes.length)
        # Creates the engine
        engine = OpenSSL::Cipher::Cipher.new('AES-128-CBC')
        # Set engine as decrypt mode
        engine.decrypt
        # Converts the key from hex to bytes
        engine.key = [keyinhex].pack('H*')
        # Converts the ivBase64 array into bytes
        engine.iv = iv_base64.pack('c*')
        # Decrypts the texts and returns the original string
        engine.update(full_data.pack('c*')) + engine.final
      end

      def encrypt(val, keyinhex)
        # Creates the engine motor
        engine = OpenSSL::Cipher::Cipher.new('AES-128-CBC')
        # Set engine as encrypt mode
        engine.encrypt
        # Converts the key from hex to bytes
        engine.key = [keyinhex].pack('H*')
        # Generates a random iv with this settings
        iv_rand = engine.random_iv
        # Packs IV as a Base64 string
        iv_base64 = [iv_rand].pack('m')
        # Converts the packed key into bytes
        unpacked = iv_base64.unpack('m')
        iv = unpacked[0]
        # Sets the IV into the engine
        engine.iv = iv
        # Encrypts the texts and stores the bytes
        encrypted_bytes = engine.update(val) + engine.final
        # Concatenates the (a) IV bytes and (b) the encrypted bytes then returns a
        # base64 representation
        [iv << encrypted_bytes].pack('m')
      end

      def authorize(money, payment, options = {})
        puts('---------------------------------------------')
        puts('Authorization')
        puts('---------------------------------------------')
        post = {
          operation: 'Authorize',
          id_comercio: self.options[:id_comercio],
          user: self.options[:user],
          apikey: self.options[:apikey]
        }
        add_invoice(post, money, options)
        # Payments contains the card information
        add_payment(post, payment)
        # Address not required
        add_address(post, payment, options)
        add_customer_data(post, options)
        post[:key_session] = self.options[:key_session]

        post_to_json = post.to_json
        puts(post_to_json)
        post_to_json_encrypt = encrypt(post_to_json, self.options[:key_session])

        final_post = post_to_json_encrypt + '-' + self.options[:user]
        commit('sale', final_post)
      end

      def capture(money, authorization, options = {})
        puts('---------------------------------------------')
        puts('Capture')
        puts('---------------------------------------------')
        post = {
          operation: 'Capture',
          id_comercio: self.options[:id_comercio],
          user: self.options[:user],
          apikey: self.options[:apikey],
          transaccion_id: options[:transaccion_id],
          amount: amount(money)
        }
        post[:key_session] = self.options[:key_session]

        post_to_json = post.to_json
        puts(post_to_json)
        post_to_json_encrypt = encrypt(post_to_json, self.options[:key_session])

        final_post = post_to_json_encrypt + '-' + self.options[:user]
        commit('capture', final_post)
      end

      def refund(money, authorization, options = {})
        puts('---------------------------------------------')
        puts('Refund')
        puts('---------------------------------------------')
        post = {
          operation: 'Refund',
          id_comercio: self.options[:id_comercio],
          user: self.options[:user],
          apikey: self.options[:apikey],
          transaccion_id: options[:transaccion_id],
          auth: authorization,
          amount: amount(money)
        }
        post[:key_session] = self.options[:key_session]

        post_to_json = post.to_json
        puts(post_to_json)
        post_to_json_encrypt = encrypt(post_to_json, self.options[:key_session])

        final_post = post_to_json_encrypt + '-' + self.options[:user]
        commit('refund', final_post)
      end

      # Currently unsupported
      # def void(authorization, options={})
      #   puts('---------------------------------------------')
      #   puts('Void')
      #   puts('---------------------------------------------')
      #   refund(options["money"], authorization, options)
      # end

      def verify(credit_card, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        false
      end

      private

      def add_customer_data(post, options)
        post[:email] = options[:email] || 'nadie@mit.test'
      end

      def add_address(post, creditcard, options); end

      def add_invoice(post, money, options)
        post[:amount] = amount(money)
        post[:currency] = (options[:currency] || currency(money))
        post[:reference] = options[:order_id]
        post[:transaccion_id] = options[:order_id]
      end

      def add_payment(post, payment)
        post[:installments] = 1
        post[:card] = payment.number
        post[:expmonth] = payment.month
        post[:expyear] = payment.year
        post[:cvv] = payment.verification_value
        post[:name_client] = [payment.first_name, payment.last_name].join(' ')
      end

      def parse(body)
        {}
      end

      def commit(action, parameters)
        url = (test? ? test_url : live_url)
        raw_response = ssl_post(url, parameters, { 'Content-type' => 'text/plain' })
        puts(raw_response)
        response = JSON.parse(decrypt(raw_response, self.options[:key_session]))
        puts(response)

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          avs_result: AVSResult.new(code: response['some_avs_response_key']),
          cvv_result: CVVResult.new(response['some_cvv_response_key']),
          test: test?,
          error_code: error_code_from(response)
        )
      end

      def success_from(response)
        response['response'] == 'approved'
      end

      def message_from(response)
        response['message']
      end

      def authorization_from(response)
        response['auth']
      end

      def post_data(action, parameters = {})
        parameters.collect { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join('&')
      end

      def error_code_from(response)
        response['message'].split(' -- ', 2)[0] unless success_from(response)
      end
    end
  end
end
