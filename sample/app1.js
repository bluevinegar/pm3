
console.log('this is a test');
console.error('this error test');

setTimeout(function () {
  console.log('exiting.');
  process.exit(1);
}, 5000);