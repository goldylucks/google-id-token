# encoding: utf-8
# Copyright 2012 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# @author Tim Bray, adapted from code by Bob Aman

require 'spec_helper'
require 'fakeweb'
require 'openssl'

CERTS_URI = 'https://www.googleapis.com/oauth2/v1/certs'

describe GoogleIDToken::Validator do

  describe '#check' do
    before(:all) do
      crypto = generate_certificate
      @key = crypto[:key]
      @cert = crypto[:cert]
    end

    let(:iss) { 'https://accounts.google.com' }
    let(:aud) { '123456789.apps.googleusercontent.com' }
    let(:cid) { '123456789.apps.googleusercontent.com' }
    let(:exp) { Time.now + 10 }

    let(:payload) {{
      exp: exp.to_i,
      iss: iss,
      aud: aud,
      cid: cid,
      sub: '12345',
      email: 'test@gmail.com',
      provider_id: 'google.com',
      verified: true
    }}

    let(:token) { JWT.encode(payload, @key, 'RS256') }

    it 'should successfully validate against a passed-in X509 cert' do
      literal_validator = GoogleIDToken::Validator.new(x509_cert: @cert)
      result = literal_validator.check(token, aud)
      expect(result).to_not be_nil
      expect(result['aud']).to eq aud
    end

    context 'with old_skool certs' do
      let(:validator) { GoogleIDToken::Validator.new }

      context 'when unable to fetch old_skool Google certs' do
        before do
          FakeWeb::register_uri(:get, CERTS_URI,
                                status: ["404", "Not found"],
                                body: 'Ouch!')
        end

        it 'raises an error' do
          expect {
            validator.check('whatever', 'whatever')
          }.to raise_error(GoogleIDToken::CertificateError)
        end
      end

      context 'when able to fetch old_skool certs' do
        before(:all) do
          crypto = generate_certificate
          @key2 = crypto[:key]
          @cert2 = crypto[:cert]
          @certs_body = JSON.dump({
           "123" => @cert.to_pem,
           "321" => @cert2.to_pem
          })
        end

        before do
          FakeWeb::register_uri(:get, CERTS_URI,
                                status: ["200", "Success"],
                                body: @certs_body)
        end

        it 'successfully validates a good token' do
          result = validator.check(token, aud, cid)
          expect(result).to_not be_nil
          expect(result['aud']).to eq aud
          expect(result['cid']).to eq cid
          expect(result['azp']).to eq cid
        end

        it 'fails to validate a mangled token' do
          bad_token = token.gsub('x', 'y')
          expect {
            validator.check(bad_token, aud, cid)
          }.to raise_error(GoogleIDToken::SignatureError)
        end

        it 'fails to validate a good token with wrong aud field' do
          expect {
            validator.check(token, aud + 'x', cid)
          }.to raise_error(GoogleIDToken::AudienceMismatchError)
        end

        it 'fails to validate a good token with wrong cid field' do
          expect {
            validator.check(token, aud, cid + 'x')
          }.to raise_error(GoogleIDToken::ClientIDMismatchError)
        end

        context 'when aud is an array' do
          let(:aud_array) { ['123456789.apps.googleusercontent.com', '987654321.apps.googleusercontent.com'] }

          it 'it checks aud against an array' do
            expect {
              validator.check(token, aud_array, cid)
            }.not_to raise_error(GoogleIDToken::AudienceMismatchError)
          end
        end

        context 'when token is expired' do
          let(:exp) { Time.now - 10 }

          it 'fails to validate a good token' do
            expect {
              validator.check(token, aud, cid)
            }.to raise_error(GoogleIDToken::ExpiredTokenError)
          end
        end

        context 'with an invalid issuer' do
          let(:iss) { 'https://accounts.fake.com' }

          it 'fails to validate a good token' do
            expect {
              validator.check(token, aud, cid)
            }.to raise_error(GoogleIDToken::InvalidIssuerError)
          end
        end

        context 'when certificates are not expired' do
          before { validator.instance_variable_set(:@certs_last_refresh, Time.now) }

          it 'fails to validate a good token' do
            expect {
              validator.check(token, aud, cid)
            }.to raise_error(GoogleIDToken::SignatureError)
          end
        end

        context 'when certificates are expired' do
          let(:validator) { GoogleIDToken::Validator.new(expiry: 60) }
          before { validator.instance_variable_set(:@certs_last_refresh, Time.now - 120) }

          it 'fails to validate a good token' do
            result = validator.check(token, aud, cid)
            expect(result).to_not be_nil
            expect(result['aud']).to eq aud
          end
        end

        it 'validates a good token with the new azp instead of cid field' do
          payload[:azp] = payload[:cid]
          payload[:cid] = nil
          result = validator.check(token, aud, cid)
          expect(result).to_not be_nil
          expect(result['aud']).to eq aud
          expect(result['cid']).to eq cid
          expect(result['azp']).to eq cid
        end
      end
    end
  end

  def generate_certificate
    key = OpenSSL::PKey::RSA.new(2048)
    public_key = key.public_key

    cert_subject = "/C=BE/O=Test/OU=Test/CN=Test"

    cert = OpenSSL::X509::Certificate.new
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse(cert_subject)
    cert.not_before = Time.now
    cert.not_after = Time.now + 365 * 24 * 60 * 60
    cert.public_key = public_key
    cert.serial = 0x0
    cert.version = 2

    cert.sign key, OpenSSL::Digest::SHA1.new

    { key: key, cert: cert }
  end
end
