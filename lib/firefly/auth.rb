require 'warden'

def register_api_key_strategy(api_key)
  Warden::Strategies.add(:api_key) do
    def valid?
      params['api_key']
    end

    define_method 'authenticate!', lambda {
      if params['api_key'] == api_key
        # There is no notion of a user in this scheme.
        # A 'default user' is used to login everybody.
        success!('default_user')
      else
        fail!("Wrong api key")
      end
    }
  end
end
