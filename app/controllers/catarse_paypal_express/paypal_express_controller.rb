class CatarsePaypalExpress::PaypalExpressController < ApplicationController
  include ActiveMerchant::Billing::Integrations

  skip_before_filter :force_http

  SCOPE = "projects.contributions.checkout"
  layout :false

  def review
  end

  def ipn
    if contribution && notification.acknowledge && (contribution.payment_method == 'PayPal' || contribution.payment_method.nil?)
      process_paypal_message params
      contribution.update_attributes({
        :payment_service_fee => params['mc_fee'],
        :payer_email => params['payer_email']
      })
    else
      return render status: 500, nothing: true
    end
    return render status: 200, nothing: true
  rescue Exception => e
    return render status: 500, text: e.inspect
  end

  def pay
    begin
      response = gateway.setup_purchase(contribution.price_in_cents, {
        ip: request.remote_ip,
        return_url: success_paypal_express_url(id: contribution.id),
        cancel_return_url: cancel_paypal_express_url(id: contribution.id),
        currency_code: 'USD',
        description: t('paypal_description', scope: SCOPE, :project_name => contribution.project.name, :value => contribution.value),
        notify_url: ipn_paypal_express_index_url(subdomain: 'www')
      })

      process_paypal_message response.params
      contribution.payments.create(gateway_data: {token: response.token}, payment_method: "PayPal", gateway: "PayPal")
      redirect_to gateway.redirect_url_for(response.token)
    rescue Exception => e
      Rails.logger.info "-----> #{e.inspect}"
      flash[:failure] = t('paypal_error', scope: SCOPE)
      return redirect_to main_app.new_project_contribution_path(contribution.project)
    end
  end

  def success
    begin
      purchase = gateway.purchase(contribution.price_in_cents, {
        ip: request.remote_ip,
        token: payment.gateway_data['token'],
        payer_id: params[:PayerID]
      })

      # we must get the deatils after the purchase in order to get the transaction_id
      process_paypal_message purchase.params

      flash[:success] = t('success', scope: SCOPE)
      redirect_to main_app.project_contribution_path(project_id: contribution.project.id, id: contribution.id)
    rescue Exception => e
      Rails.logger.info "-----> #{e.inspect}"
      flash[:failure] = t('paypal_error', scope: SCOPE)
      return redirect_to main_app.new_project_contribution_path(contribution.project)
    end
  end

  def cancel
    flash[:failure] = t('paypal_cancel', scope: SCOPE)
    redirect_to main_app.new_project_contribution_path(contribution.project)
  end

  def contribution
    @contribution ||= if params['id']
      PaymentEngines.find_contribution(params['id'])
    end
  end

  def payment
    @payment ||= if params['token']
      Payment.where("gateway_data->>'token' = ?", params['token']).first
    end
  end

  def process_paypal_message(data)
    extra_data = (data['charset'] ? JSON.parse(data.to_json.force_encoding(data['charset']).encode('utf-8')) : data)
    PaymentEngines.create_payment_notification contribution_id: contribution.id, extra_data: extra_data

    if data["checkout_status"] == 'PaymentActionCompleted'
      contribution.confirm!
    elsif data["payment_status"]
      case data["payment_status"].downcase
      when 'completed'
        payment.pay!
      when 'refunded'
        contribution.refund!
      when 'canceled_reversal'
        contribution.cancel!
      when 'expired', 'denied'
        contribution.pendent!
      else
        contribution.waiting! if contribution.pending?
      end
    end
  end

  def gateway
    @gateway ||= CatarsePaypalExpress::Gateway.instance
  end

  protected

  def notification
    @notification ||= Paypal::Notification.new(request.raw_post)
  end
end
