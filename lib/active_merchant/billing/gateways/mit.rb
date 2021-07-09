require 'json'
require 'openssl'
require 'digest'
require 'base64'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class MitGateway < Gateway
      self.live_url = 'https://wpy.mitec.com.mx/ModuloUtilWS/activeCDP.htm'

      self.supported_countries = ['MX']
      self.default_currency = 'MXN'

      self.supported_cardtypes = %i[visa master]

      self.homepage_url = 'http://www.centrodepagos.com.mx/'
      self.display_name = 'MIT Centro de pagos'

      self.money_format = :dollars

      def initialize(options = {})
        requires!(options, :commerce_id, :user, :api_key, :key_session, :test)
        super
      end

      def purchase(money, payment, options = {})
        authorization = authorize(money, payment, options)
        return authorization unless authorization.success?

        capture(money, payment, options)
      end

      def cipher_key
        @options[:key_session]
      end

      def decrypt(val, keyinhex)
        # Splits the first 16 bytes (the IV bytes) in array format
        unpacked = val.unpack('m')
        iv_base64 = unpacked[0].bytes.slice(0, 16)
        # Splits the second bytes (the encrypted text bytes) these would be the
        # original message
        full_data = unpacked[0].bytes.slice(16, unpacked[0].bytes.length)
        # Creates the engine
        engine = OpenSSL::Cipher::AES128.new(:CBC)
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
        engine = OpenSSL::Cipher::AES128.new(:CBC)
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
        post = {
          operation: 'Authorize',
          commerce_id: @options[:commerce_id],
          user: @options[:user],
          apikey: @options[:api_key],
          testMode: (test? ? 'YES' : 'NO')
        }
        add_invoice(post, money, options)
        # Payments contains the card information
        add_payment(post, payment)
        add_customer_data(post, options)
        post[:key_session] = @options[:key_session]

        post_to_json = post.to_json
        post_to_json_encrypt = encrypt(post_to_json, @options[:key_session])

        final_post = '<authorization>' + post_to_json_encrypt + '</authorization><dataID>' + @options[:user] + '</dataID>'
        json_post = {}
        json_post[:payload] = final_post
        commit('sale', json_post)
      end

      def capture(money, authorization, options = {})
        post = {
          operation: 'Capture',
          commerce_id: @options[:commerce_id],
          user: @options[:user],
          apikey: @options[:api_key],
          testMode: (test? ? 'YES' : 'NO'),
          transaction_id: options[:transaction_id],
          amount: amount(money)
        }
        post[:key_session] = @options[:key_session]

        post_to_json = post.to_json
        post_to_json_encrypt = encrypt(post_to_json, @options[:key_session])

        final_post = '<capture>' + post_to_json_encrypt + '</capture><dataID>' + @options[:user] + '</dataID>'
        json_post = {}
        json_post[:payload] = final_post
        commit('capture', json_post)
      end

      def refund(money, authorization, options = {})
        post = {
          operation: 'Refund',
          commerce_id: @options[:commerce_id],
          user: @options[:user],
          apikey: @options[:api_key],
          testMode: (test? ? 'YES' : 'NO'),
          transaction_id: options[:transaction_id],
          auth: authorization,
          amount: amount(money)
        }
        post[:key_session] = @options[:key_session]

        post_to_json = post.to_json
        post_to_json_encrypt = encrypt(post_to_json, @options[:key_session])

        final_post = '<refund>' + post_to_json_encrypt + '</refund><dataID>' + @options[:user] + '</dataID>'
        json_post = {}
        json_post[:payload] = final_post
        commit('refund', json_post)
      end

      def verify(credit_card, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        ret_transcript = transcript
        auth_origin = ret_transcript[/<authorization>(.*?)<\/authorization>/,1]
        if !auth_origin.nil? then
          auth_decrypted = decrypt(auth_origin,@options[:key_session])
          auth_json = JSON.parse(auth_decrypted)
          auth_json['card'] = '[FILTERED]'
          auth_json['expmonth'] = '[FILTERED]'
          auth_json['expyear'] = '[FILTERED]'
          auth_json['cvv'] = '[FILTERED]'
          auth_json['name_client'] = '[FILTERED]'
          auth_json['email'] = '[FILTERED]'
          auth_json['apikey'] = '[FILTERED]'
          auth_to_json = auth_json.to_json
          auth_encrypted = encrypt(auth_to_json,@options[:key_session])
          auth_tagged = '<authorization>' + auth_encrypted + '</authorization>'
          ret_transcript = ret_transcript.gsub(/<authorization>(.*?)<\/authorization>/, auth_tagged)
        end

        cap_origin = ret_transcript[/<capture>(.*?)<\/capture>/,1]
        if !cap_origin.nil? then
          cap_decrypted = decrypt(cap_origin,@options[:key_session])
          cap_json = JSON.parse(cap_decrypted)
          cap_json['apikey'] = '[FILTERED]'
          cap_to_json = cap_json.to_json
          cap_encrypted = encrypt(cap_to_json,@options[:key_session])
          cap_tagged = '<capture>' + cap_encrypted + '</capture>'
          ret_transcript = ret_transcript.gsub(/<capture>(.*?)<\/capture>/, cap_tagged)          
        end

        ref_origin = ret_transcript[/<refund>(.*?)<\/refund>/,1]
        if !ref_origin.nil? then
          ref_decrypted = decrypt(ref_origin,@options[:key_session])
          ref_json = JSON.parse(ref_decrypted)
          ref_json['apikey'] = '[FILTERED]'
          ref_to_json = ref_json.to_json
          ref_encrypted = encrypt(ref_to_json,@options[:key_session])
          ref_tagged = '<capture>' + ref_encrypted + '</capture>'
          ret_transcript = ret_transcript.gsub(/<capture>(.*?)<\/capture>/, ref_tagged)          
        end

        ret_transcript.
          gsub('payload', '\1[FILTERED]\3')
      end

      private

      def add_customer_data(post, options)
        post[:email] = options[:email] || 'nadie@mit.test'
      end

      def add_invoice(post, money, options)
        post[:amount] = amount(money)
        post[:currency] = (options[:currency] || currency(money))
        post[:reference] = options[:order_id]
        post[:transaction_id] = options[:order_id]
      end

      def add_payment(post, payment)
        post[:installments] = 1
        post[:card] = payment.number
        post[:expmonth] = payment.month
        post[:expyear] = payment.year
        post[:cvv] = payment.verification_value
        post[:name_client] = [payment.first_name, payment.last_name].join(' ')
      end

      def commit(action, parameters)
        json_str = parameters.to_json
        cleaned_str = json_str.gsub('\n','')
        raw_response = ssl_post(live_url, cleaned_str, { 'Content-type' => 'application/json' })
        response = JSON.parse(decrypt(raw_response, @options[:key_session]))

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
        response['response']
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
