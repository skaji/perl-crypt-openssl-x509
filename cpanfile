requires 'Convert::ASN1', '0.33';

on 'configure' => sub {
  requires 'Crypt::OpenSSL::Guess', '0.15';
};

on 'test' => sub {
  requires 'Test::Pod', '>= 1.00';
};