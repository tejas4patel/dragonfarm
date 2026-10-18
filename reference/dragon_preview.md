# Preview mapped rows as chat turns

Preview mapped rows as chat turns

## Usage

``` r
dragon_preview(dataset, n = 3)
```

## Arguments

- dataset:

  A mapped `dragon_dataset`.

- n:

  Number of rows to show.

## Value

Invisibly, a list of message lists.

## Examples

``` r
ds <- dragon_map(dragon_dataset(dragon_example_data()),
                 prompt = "{subject}\n\n{body}", response = "reply")
dragon_preview(ds, n = 2)
#> 
#> ── Row 1 
#> user:
#> Ember thermostat keeps dropping off Wi-Fi
#> 
#> I've tried setting up my Ember thermostat three times and it never gets past the Wi-Fi step. The app just says 'connection failed'. My phone is on the same 2.4 GHz network.
#> assistant:
#> Thanks for the details. Wi-Fi drops on the Ember thermostat are almost always a 2.4 GHz band-steering issue with mesh routers. Please try these steps: (1) In your router app, create a dedicated 2.4 GHz network or temporarily disable band steering. (2) Hold the reset button on the Ember thermostat for 10 seconds until the light blinks amber. (3) Set it up again in the app on that 2.4 GHz network. If it still drops after 24 hours, reply with your router model and we will escalate to our network team.
#> 
#> ── Row 2 
#> user:
#> Invoice total is wrong
#> 
#> The invoice for my Nook speaker shows a higher total than the price on the checkout page. Looks like tax was applied twice.
#> assistant:
#> Sorry about the confusion with your Nook speaker charge. I've looked at the order on our side. When a payment is authorized and then captured, some banks show both as separate pending lines for 2 to 3 business days before the authorization drops off. If both charges are still showing after 3 business days, reply here with the last four digits of the card and the order number and we will refund the duplicate within one business day. Either way, you will only ever be charged once for the Nook speaker.
```
