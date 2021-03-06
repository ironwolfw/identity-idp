shared_examples 'remember device' do
  it 'does not require 2FA on sign in' do
    user = remember_device_and_sign_out_user
    sign_in_user(user)

    expect(current_path).to eq(account_path)
  end

  it 'requires 2FA on sign in after expiration' do
    user = remember_device_and_sign_out_user

    days_to_travel = (Figaro.env.remember_device_expiration_hours_aal_1.to_i + 1).hours.from_now
    Timecop.travel days_to_travel do
      sign_in_user(user)

      expect(current_path).to eq(login_two_factor_path(otp_delivery_preference: :sms))
    end
  end

  it 'requires 2FA on sign in after phone number is changed' do
    user = remember_device_and_sign_out_user

    # Ensure that at least 1 second has passed since last `remember device`
    sleep(1)

    sign_in_user(user)
    visit manage_phone_path
    fill_in 'user_phone_form_phone', with: '7032231000'
    click_button t('forms.buttons.submit.confirm_change')
    click_submit_default
    first(:link, t('links.sign_out')).click

    sign_in_user(user)

    expect(current_path).to eq(login_two_factor_path(otp_delivery_preference: :sms))
  end

  it 'requires 2FA on sign in for another user' do
    first_user = remember_device_and_sign_out_user

    second_user = user_with_2fa

    # Sign in as second user and expect otp confirmation
    sign_in_user(second_user)
    expect(current_path).to eq(login_two_factor_path(otp_delivery_preference: :sms))

    # Setup remember device as second user
    check :remember_device
    click_submit_default

    # Sign out second user
    first(:link, t('links.sign_out')).click

    # Sign in as first user again and expect otp confirmation
    sign_in_user(first_user)
    expect(current_path).to eq(login_two_factor_path(otp_delivery_preference: :sms))
  end

  it 'redirects to an SP from the sign in page' do
    oidc_url = openid_connect_authorize_url(
      client_id: 'urn:gov:gsa:openidconnect:sp:server',
      response_type: 'code',
      acr_values: Saml::Idp::Constants::LOA1_AUTHN_CONTEXT_CLASSREF,
      scope: 'openid email',
      redirect_uri: 'http://localhost:7654/auth/result',
      state: SecureRandom.hex,
      nonce: SecureRandom.hex,
    )
    user = remember_device_and_sign_out_user

    IdentityLinker.new(
      user, 'urn:gov:gsa:openidconnect:sp:server'
    ).link_identity(verified_attributes: %w[email])

    visit oidc_url
    click_link t('links.sign_in')

    expect(page.response_headers['Content-Security-Policy']).
      to(include('form-action \'self\' http://localhost:7654'))

    sign_in_user(user)

    expect(current_url).to start_with('http://localhost:7654/auth/result')
  end
end

shared_examples 'remember device after being idle on sign in page' do
  it 'redirects to the OIDC SP even though session is deleted' do
    # We want to simulate a user that has already visited an OIDC SP and that
    # has checked "remember me for 30 days", such that the next URL the app will
    # redirect to after signing in with email and password is the SP redirect
    # URI.
    user = remember_device_and_sign_out_user
    IdentityLinker.new(
      user, 'urn:gov:gsa:openidconnect:sp:server'
    ).link_identity(verified_attributes: %w[email])

    visit_idp_from_sp_with_loa1(:oidc)
    request_id = ServiceProviderRequest.last.uuid
    click_link t('links.sign_in')

    Timecop.travel(Devise.timeout_in + 1.minute) do
      # Simulate being idle on the sign in page long enough for the session to
      # be deleted from Redis, but since Redis doesn't respect Timecop, we need
      # to expire the session manually.
      session_store.send(:destroy_session_from_sid, session_cookie.value)
      # Simulate refreshing the page with JS to avoid a CSRF error
      visit new_user_session_url(request_id: request_id)

      expect(page.response_headers['Content-Security-Policy']).
        to(include('form-action \'self\' http://localhost:7654/auth/result'))

      fill_in_credentials_and_submit(user.email, user.password)

      expect(current_url).to start_with('http://localhost:7654/auth/result')
    end
  end
end
