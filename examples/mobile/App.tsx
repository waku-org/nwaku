/* eslint-disable no-alert */
/**
 * Sample React Native App
 * https://github.com/facebook/react-native
 *
 * @format
 */

import React from 'react';
import type {PropsWithChildren} from 'react';
import {
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from 'react-native';

import {
  Colors,
  DebugInstructions,
  Header,
  LearnMoreLinks,
  ReloadInstructions,
} from 'react-native/Libraries/NewAppScreen';
import {NativeModules, Button} from 'react-native';

type SectionProps = PropsWithChildren<{
  title: string;
}>;

function Section({children, title}: SectionProps): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';
  return (
    <View style={styles.sectionContainer}>
      <Text
        style={[
          styles.sectionTitle,
          {
            color: isDarkMode ? Colors.white : Colors.black,
          },
        ]}>
        {title}
      </Text>
      <Text
        style={[
          styles.sectionDescription,
          {
            color: isDarkMode ? Colors.light : Colors.dark,
          },
        ]}>
        {children}
      </Text>
    </View>
  );
}

function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';

  const backgroundStyle = {
    backgroundColor: isDarkMode ? Colors.darker : Colors.lighter,
  };

  const onClickSetup = async () => {
    await NativeModules.WakuModule.setup();
    alert('Waku lib setup complete');
  };

  var wakuPtr: Number;

  const onClickNew = async () => {
    const config = {
      host: '0.0.0.0',
      port: 42342,
      key: '1122334455667788990011223344556677889900112233445566778899000022',
      relay: true,
    };
    wakuPtr = await NativeModules.WakuModule.new(config);
    alert('waku_new result: ' + wakuPtr);
  };

  const onClickStart = async () => {
    await NativeModules.WakuModule.start(wakuPtr);
    alert('start executed succesfully');
  };

  const onClickVersion = async () => {
    let version = await NativeModules.WakuModule.version(wakuPtr);
    alert('version result: ' + version);
  };

  const onClickListenAddresses = async () => {
    let addresses = await NativeModules.WakuModule.listenAddresses(wakuPtr);
    alert(addresses[0]);
  };

  const onClickStop = async () => {
    await NativeModules.WakuModule.stop(wakuPtr);
    alert('stopped!');
  };

  const onClickDestroy = async () => {
    await NativeModules.WakuModule.destroy(wakuPtr);
    alert('destroyed!');
  };

  const onClickConnect = async () => {
    let result = await NativeModules.WakuModule.connect(
      wakuPtr,
      '/ip4/127.0.0.1/tcp/48117/p2p/16Uiu2HAmVrsyU3y3pQYuSEyaqrBgevQeshp7YZsL8rY3nWb2yWD5',
      0,
    );
    alert('connect: ' + result);
  };

  const onClickSubscribe = async () => {
    await NativeModules.WakuModule.relaySubscribe(wakuPtr, 'test');
    alert('subscribed to test');
  };

  const onClickUnsubscribe = async () => {
    await NativeModules.WakuModule.relayUnsubscribe(wakuPtr, 'test');
    alert('unsubscribed from test');
  };

  return (
    <SafeAreaView style={backgroundStyle}>
      <StatusBar
        barStyle={isDarkMode ? 'light-content' : 'dark-content'}
        backgroundColor={backgroundStyle.backgroundColor}
      />
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        style={backgroundStyle}>
        <View
          style={{
            backgroundColor: isDarkMode ? Colors.black : Colors.white,
          }}>
          <Section>
            <Button title="Setup" color="#841584" onPress={onClickSetup} />
          </Section>
          <Section>
            <Button title="New" color="#841584" onPress={onClickNew} />
          </Section>
          <Section>
            <Button title="Start" color="#841584" onPress={onClickStart} />
          </Section>
          <Section>
            <Button title="Version" color="#841584" onPress={onClickVersion} />
          </Section>
          <Section>
            <Button
              title="ListenAddresses"
              color="#841584"
              onPress={onClickListenAddresses}
            />
          </Section>
          <Section>
            <Button title="Connect" color="#841584" onPress={onClickConnect} />
          </Section>
          <Section>
            <Button
              title="Subscribe"
              color="#841584"
              onPress={onClickSubscribe}
            />
          </Section>
          <Section>
            <Button
              title="Unsubscribe"
              color="#841584"
              onPress={onClickUnsubscribe}
            />
          </Section>
          <Section>
            <Button title="Stop" color="#841584" onPress={onClickStop} />
          </Section>
          <Section>
            <Button title="Destroy" color="#841584" onPress={onClickDestroy} />
          </Section>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  sectionContainer: {
    marginTop: 32,
    paddingHorizontal: 24,
  },
  sectionTitle: {
    fontSize: 24,
    fontWeight: '600',
  },
  sectionDescription: {
    marginTop: 8,
    fontSize: 18,
    fontWeight: '400',
  },
  highlight: {
    fontWeight: '700',
  },
});

export default App;
