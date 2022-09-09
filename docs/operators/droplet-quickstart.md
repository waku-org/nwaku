# Quickstart for running nwaku on a DigitalOcean Droplet

This guide explains how to run a nwaku node on a 
DigitalOcean Droplet. We enable the following protocols -

1. Relay
2. Store
3. DNS Discovery
4. Discv5

## 1. Get the `doctl` binary

Follow this [guide](https://docs.digitalocean.com/reference/doctl/how-to/install/) to install,
and configure the `doctl` cli, which will help with setting up the Droplet.

## 2. Set up SSH credentials

Run the following command -
```bash
export DROPLET_SSH_KEY_PATH=~/.ssh/id_nwaku_droplet
ssh-keygen -f $DROPLET_SSH_KEY_PATH
```

Press `enter` twice, i.e do NOT set a passphrase.

Run the following command -
```bash
export DROPLET_SSH_PUBLIC_KEY=$(cat "$DROPLET_SSH_KEY_PATH".pub)
```

*Alternatively*, if you would like to supply your own credentials, make sure that the public key is in the `DROPLET_SSH_PUBLIC_KEY` env variable.


Lastly, add the ssh key to your DigitalOcean account -
```bash
doctl compute ssh-key create nwaku-key --public-key=$DROPLET_SSH_PUBLIC_KEY
```

## 3. Select the region closest to you

Run the following command to get the list of available
regions -

```bash
doctl compute region list | grep true
```

You should get an output similar to this -

```bash
nyc1    New York 1         true
sgp1    Singapore 1        true
lon1    London 1           true
nyc3    New York 3         true
ams3    Amsterdam 3        true
fra1    Frankfurt 1        true
tor1    Toronto 1          true
blr1    Bangalore 1        true
sfo3    San Francisco 3    true
```
Choose the region closest to you, and run the following command -

```bash
export DROPLET_REGION=<slug>
```

For example, if you live in NYC -
```bash
export DROPLET_REGION=nyc1
```

Note that it is *optional* to choose the datacenter closest to you. This is merely done for operational efficiency.

## 4. Select the OS distribution

Run the following command to get the list of distributions -

```bash
doctl compute image list-distribution
```

You should get an output similar to this -

```bash
ID           Name                  Type        Distribution    Slug                   Public    Min Disk
78547182     1.5.8 x64             snapshot    RancherOS       rancheros              true      15
106433672    7 x64                 snapshot    CentOS          centos-7-x64           true      9
106434098    9 Stream x64          snapshot    CentOS          centos-stream-9-x64    true      10
106434191    8 Stream x64          snapshot    CentOS          centos-stream-8-x64    true      10
...
```

Choose the distribution you are most comfortable with, and then run the following command

```bash
export DROPLET_IMAGE=<slug>
```

For example, if you chose Debian 11 x64 -

```bash
export DROPLET_IMAGE=debian-11-x64
```

## 5. Select the size of the Droplet

Run the following command to get the list of Droplet sizes for the previously selected region -

```bash
doctl compute size list
```

You should get an output similar to this -
```bash
Slug                  Description                   Memory    VCPUs    Disk    Price Monthly    Price Hourly
s-1vcpu-512mb-10gb    Basic                         512       1        10      4.00             0.005950
s-1vcpu-1gb           Basic                         1024      1        25      6.00             0.008930
s-1vcpu-1gb-amd       Basic AMD                     1024      1        25      7.00             0.010420
s-1vcpu-1gb-intel     Basic Intel                   1024      1        25      7.00             0.010420
s-1vcpu-2gb           Basic                         2048      1        50      12.00            0.017860
s-1vcpu-2gb-amd       Basic AMD                     2048      1        50      14.00            0.020830
s-1vcpu-2gb-intel     Basic Intel                   2048      1        50      14.00            0.020830
s-2vcpu-2gb           Legacy Basic                  2048      2        60      18.00            0.026790
...
```

> Note: To compile the nwaku binary, a minimum of 2GB of RAM is required. You may choose a smaller Droplet, however, you would have to supply the binary in an alternate manner, i.e via the official release on Github, or compiling it on another machine and copying it over. Currently, we only supply binaries for macOS and Ubuntu.

Choose the Droplet size that you are most comfortable with, and then run the following command -

```bash
export DROPLET_SIZE=<slug>
```

For example, `s-1vcpu-2gb` is more than capable to handle the protocols we mentioned above -

```bash
export DROPLET_SIZE=s-1vcpu-2gb
```

## 6. Create the Droplet

Run the following command to create the droplet -

```bash
export DROPLET_ID=$(doctl compute droplet create --region=$DROPLET_REGION --image=$DROPLET_IMAGE --size=$DROPLET_SIZE --enable-monitoring --format=ID --wait <your-droplet-name> | sed -n2p)
```

For example, to create a droplet named `nwaku` -

```bash
export DROPLET_ID=$(doctl compute droplet create --region=$DROPLET_REGION --image=$DROPLET_IMAGE --size=$DROPLET_SIZE --enable-monitoring --format=ID --wait nwaku | sed -n2p)
```

## 7. Create a Domain and attach it to the droplet

Follow this [guide](https://docs.digitalocean.com/products/networking/dns/how-to/add-domains/) to create a domain, and add it to the droplet appropriately.

## 8. SSH into the Droplet

You can get the following details in the email that DigitalOcean sends upon successful creation of the Droplet -

1. username
2. password
3. public ipv4 address

Since the public key we previously generated was automatically added to the authorized_keys list, we can run the following command to ssh into the Droplet -

```bash
export USERNAME=<username from email>
export IP=<public ipv4 address from email>
ssh -i $DROPLET_SSH_KEY_PATH $USERNAME@$IP
```

For example, if the username was `root`, and the ipv4 address was `0.0.0.0`,

```bash
export USERNAME=root
export IP=0.0.0.0
ssh -i $DROPLET_SSH_KEY_PATH $USERNAME@$IP
```

## 9. Build nwaku

To build `nwaku`, follow this [guide](./how-to/build.md)

OR

To fetch the latest release from Github, navigate to https://github.com/status-im/nwaku/releases and download the latest tarball for your distribution.

This [guide](https://www.itprotoday.com/development-techniques-and-management/how-install-targz-file-ubuntu-linux) describes how to install a tarball for your distribution.

OR

Run the following script to copy over the wakunode2 binary (from the host machine) -

```bash
scp -i $DROPLET_SSH_KEY_PATH ./wakunode2 $USERNAME@$IP:~/wakunode2
```

## 10. Run nwaku

Run the following command to run `nwaku` -

*Note the path to the wakunode2 binary*

```bash
./build/wakunode2 \
  --store:true \
  --storenode:/dns4/node-01.ac-cn-hongkong-c.wakuv2.test.statusim.net/tcp/30303/p2p/16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm \
  --dns-discovery \
  --dns-discovery-url:enrtree://AOFTICU2XWDULNLZGRMQS4RIZPAZEHYMV4FYHAPW563HNRAOERP7C@test.waku.nodes.status.im
  --dns4-domain-name=<the-domain-name>
  --discv5-discovery:true &
```

You now have nwaku running! You can verify this by observing the logs. The logs should show that the node completed 7 steps of setup, and is actively discovering other nodes.

You may close the ssh connection now.

For alternative configurations, refer to this [guide](./how-to/configure.md)

